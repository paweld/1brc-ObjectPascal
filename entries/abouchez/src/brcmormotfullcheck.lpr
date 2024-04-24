/// MIT code (c) Arnaud Bouchez, using the mORMot 2 framework
// - slower version, with full name storage within each thread
program brcmormotfullcheck;

{$define NOPERFECTHASH}

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  mormot.core.fpcx64mm,
  cthreads,
  baseunix, // low-level fpmmap with MAP_POPULATE
  classes,
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.unicode,
  mormot.core.text,
  mormot.core.data;

type
  // a weather station info, using a whole CPU L1 cache line (64 bytes)
  TBrcStation = packed record
    NameLen: byte;
    NameText: array[1 .. 64 - 1 - 2 * 4 - 3 * 2] of AnsiChar; // maxlen = 49
    Hash16: word;         // high 16-bit of the 32-bit perfect hash
    Sum, Count: integer;  // we ensured no overflow occurs with 32-bit range
    Min, Max: SmallInt;   // 16-bit (-32767..+32768) temperatures * 10
  end;
  TBrcStations = array of TBrcStation;
  PBrcStation = ^TBrcStation;

  // state machine used for efficient per-thread line processing
  TBrcChunk = record
    NameHash: cardinal;
    Value, NameLen, MemMapSize: integer;
    Name, Start, Stop, MemMapBuf: PUtf8Char;
  end;

  // store parsed values
  TBrcList = record
    StationHash: array of word;      // store 0 if void, or Station[] index + 1
    Station: TBrcStations;
    Count: PtrInt;
    procedure Init(max: integer);
    function Add(h: PtrUInt; var chunk: TBrcChunk): PBrcStation;
    function Search(var chunk: TBrcChunk): PBrcStation; inline;
  end;

  // main processing class, orchestrating all TBrcThread instances
  TBrcMain = class
  protected
    fSafe: TOsLightLock;
    fEvent: TSynEvent;
    fRunning, fMax, fChunkSize, fCurrentChunk: integer;
    fList: TBrcList;
    fFile: THandle;
    fFileSize: Int64;
    procedure Aggregate(const another: TBrcList);
    function MemMapNext(var next: TBrcChunk): boolean;
  public
    constructor Create(const fn: TFileName; threads, chunkmb, max: integer;
      affinity: boolean);
    destructor Destroy; override;
    procedure WaitFor;
    function SortedText: RawUtf8;
  end;

  // per-thread execution
  TBrcThread = class(TThread)
  protected
    fOwner: TBrcMain;
    fList: TBrcList; // each thread work on its own list
    procedure Execute; override;
  public
    constructor Create(owner: TBrcMain);
  end;


{$ifdef OSLINUXX64}

procedure ParseLine(var chunk: TBrcChunk); nostackframe; assembler;
asm
         // 128-bit SSE2 ';" search and SSE4.2 crc32c hash
         mov      rsi, [rdi + TBrcChunk.Start]
         xor      edx, edx
         movaps   xmm0, oword ptr [rip + @pattern]
         movups   xmm1, oword ptr [rsi]      // search in first 16 bytes
         pcmpeqb  xmm1, xmm0
         mov      [rdi + TBrcChunk.Name], rsi
         pmovmskb ecx, xmm1
         bsf      ecx, ecx                   // ecx = position
         jz       @by16
         lea      rax, [rsi + rcx]           // rax = found
         test     cl, 8
         jz       @less8
         crc32    rdx, qword ptr [rsi]       // branchless for 8..15 bytes
@ok8:    crc32    rdx, qword ptr [rax - 8]   // may overlap
@ok:     mov      rcx, rax
         mov      [rdi + TBrcChunk.NameHash], edx
         sub      rcx, [rdi + TBrcChunk.Start]
         mov      [rdi + TBrcChunk.NameLen], ecx
         // branchless temperature parsing - same algorithm as pascal code below
         xor      ecx, ecx
         xor      edx, edx
         cmp      byte ptr [rax + 1], '-'
         setne    cl
         sete     dl
         lea      rsi, [rcx + rcx - 1]      // rsi = +1 or -1
         lea      r8, [rax + rdx]
         cmp      byte ptr [rax + rdx + 2], '.'
         sete     cl
         setne    dl
         mov      eax, dword ptr [r8 + 1]   // eax = xx.x or x.x
         shl      cl, 3
         lea      r8, [r8 + rdx + 5]        // r8 = next line
         shl      eax, cl                   // normalized as xx.x
         and      eax, $0f000f0f            // from ascii to digit
         imul     rax, rax, 1 + 10 shl 16 + 100 shl 24
         shr      rax, 24                   // value is computed in high bits
         and      eax, 1023                 // truncate to 3 digits (0..999)
         imul     eax, esi                  // apply sign
         mov      [rdi + TBrcChunk.Value], eax
         mov      [rdi + TBrcChunk.Start], r8
         ret
@by16:   crc32    rdx, qword ptr [rsi]      // hash 16 bytes
         crc32    rdx, qword ptr [rsi + 8]
         jmp      @nxt16
@less8:  test     cl, 4
         jz       @less4
         crc32    edx, dword ptr [rsi]      // 4..7 bytes
         crc32    edx, dword ptr [rax - 4]  // may overlap
         jmp      @ok
@less4:  crc32    edx, word ptr [rsi]       // 2..3 bytes
         crc32    edx, word ptr [rax - 2]   // may overlap
         jmp      @ok
         align    16
@nxt16:  add      rsi,  16
         movups   xmm1, oword ptr [rsi]     // search in next 16 bytes
         pcmpeqb  xmm1, xmm0
         pmovmskb ecx,  xmm1
         bsf      ecx,  ecx
         jz       @nxt16
         lea      rax, [rsi + rcx]
         jmp      @ok8
         align    16
@pattern:dq       ';;;;;;;;'
         dq       ';;;;;;;;'
end;

function CompareMem(a, b: pointer; len: PtrInt): boolean; nostackframe; assembler;
asm
        add     a, len
        add     b, len
        neg     len
        cmp     len, -8
        ja      @less8
        align   8
@by8:   mov     rax, qword ptr [a + len]
        cmp     rax, qword ptr [b + len]
        jne     @diff
        add     len, 8
        jz      @eq
        cmp     len, -8
        jna     @by8
@less8: cmp     len, -4
        ja      @less4
        mov     eax, dword ptr [a + len]
        cmp     eax, dword ptr [b + len]
        jne     @diff
        add     len, 4
        jz      @eq
@less4: cmp     len, -2
        ja      @less2
        movzx   eax, word ptr [a + len]
        movzx   ecx, word ptr [b + len]
        cmp     eax, ecx
        jne     @diff
        add     len, 2
        jz      @eq
@less2: mov     al, byte ptr [a + len]
        cmp     al, byte ptr [b + len]
        je      @eq
@diff:  xor     eax, eax
        ret
@eq:    mov     eax, 1 // = found (most common case of no hash collision)
end;

{$else}

procedure ParseLine(var chunk: TBrcChunk); inline;
var
  p: PUtf8Char;
  neg: PtrInt;
begin
  // parse and hash the station name
  p := chunk.Start;
  chunk.Name := p;
  inc(p, 2);
  while p^ <> ';' do
    inc(p);
  chunk.NameLen := p - chunk.Name;
  chunk.NameHash := crc32c(0, chunk.Name, chunk.NameLen); // intel/aarch64 asm
  // branchless parsing of the temperature
  neg := ord(p[1] <> '-') * 2 - 1;         // neg = +1 or -1
  inc(p, ord(p[1] = '-'));                 // ignore '-' sign
  chunk.Start := @p[ord(p[2] <> '.') + 5]; // next line
  chunk.Value := PtrInt(cardinal((QWord((PCardinal(p + 1)^ shl
                   (byte(ord(p[2] = '.') shl 3))) and $0f000f0f) *
         (1 + 10 shl 16 + 100 shl 24)) shr 24) and cardinal(1023)) * neg;
end;

{$endif OSLINUXX64}


{ TBrcList }

const
  HASHSIZE = 1 shl 17; // slightly oversized to avoid most collisions

procedure TBrcList.Init(max: integer);
begin
  assert(max <= high(StationHash[0]));
  SetLength(StationHash, HASHSIZE);
  SetLength(Station, max);
end;

function TBrcList.Add(h: PtrUInt; var chunk: TBrcChunk): PBrcStation;
var
  ndx: PtrInt;
begin
  ndx := Count;
  assert(ndx < length(Station));
  inc(Count);
  StationHash[h] := ndx + 1;
  result := @Station[ndx];
  result^.NameLen := chunk.NameLen;
  assert(chunk.NameLen <= SizeOf(result^.NameText));
  MoveFast(chunk.Name^, result^.NameText, chunk.NameLen);
  result^.Hash16 := chunk.NameHash shr 16;
  result^.Min := chunk.Value;
  result^.Max := chunk.Value;
end;

function TBrcList.Search(var chunk: TBrcChunk): PBrcStation;
var
  h, x: PtrUInt;
begin
  h := chunk.NameHash;
  repeat
    h := h and (HASHSIZE - 1);
    x := StationHash[h];
    if x = 0 then
      break;   // void slot
    result := @Station[x - 1];
    if (result^.NameLen = chunk.NameLen) and
       {$ifdef NOPERFECTHASH}
       CompareMem(@result^.NameText, chunk.Name, chunk.NameLen) then
       {$else}
       (result^.Hash16 = chunk.NameHash shr 16) then
       {$endif NOPERFECTHASH}
      exit;   // found this perfect hash = found this station name
    inc(h);   // hash modulo collision: linear probing
  until false;
  result := Add(h, chunk);
end;


{ TBrcThread }

constructor TBrcThread.Create(owner: TBrcMain);
begin
  fOwner := owner;
  FreeOnTerminate := true;
  fList.Init(fOwner.fMax);
  InterlockedIncrement(fOwner.fRunning);
  inherited Create({suspended=}false);
end;

procedure TBrcThread.Execute;
var
  chunk: TBrcChunk;
  s: PBrcStation;
  v: integer;
begin
  chunk.MemMapBuf := nil;
  while fOwner.MemMapNext(chunk) do
  begin
    // parse this thread chunk
    repeat
      // parse next name;temp pattern into value * 10
      ParseLine(chunk);
      // store the value into the proper slot
      s := fList.Search(chunk);
      v := chunk.Value;
      inc(s^.Sum, v);
      inc(s^.Count);
      if v < s^.Min then // branches are fine
        s^.Min := v;
      if v > s^.Max then
        s^.Max := v;
    until chunk.start >= chunk.stop;
  end;
  // aggregate this thread values into the main list
  fOwner.Aggregate(fList);
end;


{ TBrcMain }

constructor TBrcMain.Create(const fn: TFileName; threads, chunkmb, max: integer;
  affinity: boolean);
var
  i, cores, core: integer;
  one: TBrcThread;
begin
  fSafe.Init;
  fEvent := TSynEvent.Create;
  fFile := FileOpenSequentialRead(fn);
  fFileSize := FileSize(fFile);
  if fFileSize <= 0 then
    raise ESynException.CreateUtf8('Impossible to find %', [fn]);
  fMax := max;
  fChunkSize := chunkmb shl 20;
  core := 0;
  cores := SystemInfo.dwNumberOfProcessors;
  for i := 0 to threads - 1 do
  begin
    one := TBrcThread.Create(self);
    if not affinity then
      continue;
    SetThreadCpuAffinity(one, core);
    inc(core, 2);
    if core >= cores then
      dec(core, cores - 1); // e.g. 0,2,1,3,0,2.. with 4 cpus
  end;
end;

destructor TBrcMain.Destroy;
begin
  inherited Destroy;
  fEvent.Free;
  fSafe.Done;
end;

const
  // read-ahead on the file to avoid page faults - need Linux kernel > 2.5.46
  MAP_POPULATE = $08000;

function TBrcMain.MemMapNext(var next: TBrcChunk): boolean;
var
  chunk, page, pos: Int64;
begin
  result := false;
  if next.MemMapBuf <> nil then
    fpmunmap(next.MemMapBuf, next.MemMapSize);
  pos := Int64(InterlockedIncrement(fCurrentChunk) - 1) {%H-}* fChunkSize;
  chunk := fFileSize - pos;
  if chunk <= 0 then
    exit; // reached end of file
  if chunk > fChunkSize then
    chunk := fChunkSize;
  // we include the previous 4KB memory page to parse full lines
  page := SystemInfo.dwPageSize;
  if pos = 0 then
    page := 0;
  next.MemMapSize := chunk + page;
  next.MemMapBuf := fpmmap(nil, next.MemMapSize, PROT_READ,
    MAP_SHARED or MAP_POPULATE, fFile, pos - page);
  if next.MemMapBuf = nil then
    exit; // invalid file
  result  := true;
  next.Start := next.MemMapBuf + page;
  if page <> 0 then
    next.Start := GotoNextLine(next.Start - 64); // = previous next.Stop
  next.Stop := next.MemMapBuf + page + chunk;
  if chunk = fChunkSize then
    next.Stop := GotoNextLine(next.Stop - 64)    // = following next.Start
  else
    while next.Stop[-1] <= ' ' do                // until end of last chunk
      dec(next.Stop);
end;

procedure TBrcMain.Aggregate(const another: TBrcList);
var
  n: integer;
  s, d: PBrcStation;
  chunk: TBrcChunk;
  line: array[0 .. 63] of AnsiChar; // "fake" ParseLine() compatible format
begin
  fSafe.Lock; // several TBrcThread are likely to finish at the same time
  if fList.Count = 0 then
    fList := another
  else
  begin
    n := another.Count;
    s := pointer(another.Station);
    repeat
      MoveFast(s^.NameText, line{%H-}, s^.NameLen);
      line[s^.NameLen] := ';';
      chunk.Start := @line;
      ParseLine(chunk);
      d := fList.Search(chunk);
      inc(d^.Count, s^.Count);
      inc(d^.Sum, s^.Sum);
      if s^.Max > d^.Max then
        d^.Max := s^.Max;
      if s^.Min < d^.Min then
        d^.Min := s^.Min;
      inc(s);
      dec(n);
    until n = 0;
  end;
  fSafe.UnLock;
  if InterlockedDecrement(fRunning) = 0 then
    fEvent.SetEvent; // all threads finished: release WaitFor method
end;

procedure TBrcMain.WaitFor;
begin
  fEvent.WaitForEver;
end;

procedure AddTemp(w: TTextWriter; sep: AnsiChar; val: PtrInt);
var
  d10: PtrInt;
begin
  w.Add(sep);
  if val < 0 then
  begin
    w.Add('-');
    val := -val;
  end;
  d10 := val div 10; // val as temperature * 10
  w.AddString(SmallUInt32Utf8[d10]); // in 0..999 range
  w.Add('.');
  w.Add(AnsiChar(val - d10 * 10 + ord('0')));
end;

function ceil(x: double): PtrInt; // "official" rounding method
begin
  result := trunc(x) + ord(frac(x) > 0);  // using FPU is fast enough here
end;

function ByStationName(const A, B): integer;
var
  sa: TBrcStation absolute A;
  sb: TBrcStation absolute B;
  la, lb: PtrInt;
begin
  la := sa.NameLen;
  lb := sb.NameLen;
  if la < lb then
    la := lb;
  result := MemCmp(@sa.NameText, @sb.NameText, la);
  if result = 0 then
    result := sa.NameLen - sb.NameLen;
end;

function TBrcMain.SortedText: RawUtf8;
var
  n: integer;
  s: PBrcStation;
  st: TRawByteStringStream;
  w: TTextWriter;
  tmp: TTextWriterStackBuffer;
begin
  // compute the sorted-by-name indexes of all stations
  assert(fList.Count <> 0);
  DynArrayFakeLength(fList.Station, fList.Count);
  DynArray(TypeInfo(TBrcStations), fList.Station).Sort(ByStationName);
  // generate output
  FastSetString(result, nil, 1200000); // pre-allocate result
  st := TRawByteStringStream.Create(result);
  try
    w := TTextWriter.Create(st, @tmp, SizeOf(tmp));
    try
      w.Add('{');
      n := fList.Count;
      s := pointer(fList.Station);
      repeat
        assert(s^.Count <> 0);
        w.AddNoJsonEscape(@s^.NameText, s^.NameLen);
        AddTemp(w, '=', s^.Min);
        AddTemp(w, '/', ceil(s^.Sum / s^.Count)); // average
        AddTemp(w, '/', s^.Max);
        dec(n);
        if n = 0 then
          break;
        w.Add(',', ' ');
        inc(s);
      until false;
      w.Add('}');
      w.FlushFinal;
      FakeLength(result, w.WrittenBytes);
    finally
      w.Free;
    end;
  finally
    st.Free;
  end;
end;

var
  fn: TFileName;
  threads, chunkmb: integer;
  verbose, affinity, help: boolean;
  main: TBrcMain;
  res: RawUtf8;
  start, stop: Int64;
begin
  assert(SizeOf(TBrcStation) = 64); // 64 = CPU L1 cache line size
  // read command line parameters
  Executable.Command.ExeDescription := 'The mORMot One Billion Row Challenge';
  if Executable.Command.Arg(0, 'the data source #filename') then
    Utf8ToFileName(Executable.Command.Args[0], fn{%H-});
  verbose := Executable.Command.Option(
    ['v', 'verbose'], 'generate verbose output with timing');
  affinity := Executable.Command.Option(
    ['a', 'affinity'], 'force thread affinity to a single CPU core');
  Executable.Command.Get(
    ['t', 'threads'], threads, '#number of threads to run',
      SystemInfo.dwNumberOfProcessors);
  Executable.Command.Get(
    ['c', 'chunk'], chunkmb, 'size in #megabytes used for per-thread chunking', 16);
  help := Executable.Command.Option(['h', 'help'], 'display this help');
  if Executable.Command.ConsoleWriteUnknown then
    exit
  else if help or
     (fn = '') then
  begin
    ConsoleWrite(Executable.Command.FullDescription);
    exit;
  end;
  // actual process
  if verbose then
    ConsoleWrite(['Processing ', fn, ' with ', threads, ' threads, ',
      chunkmb, 'MB chunks and affinity=', affinity]);
  QueryPerformanceMicroSeconds(start);
  try
    main := TBrcMain.Create(fn, threads, chunkmb, {max=}45000, affinity);
    // note: current stations count = 41343 for 2.5MB of data per thread
    try
      main.WaitFor;
      res := main.SortedText;
      if verbose then
        ConsoleWrite(['result hash=',      CardinalToHexShort(crc32cHash(res)),
                      ', result length=',  length(res),
                      ', stations count=', main.fList.Count,
                      ', valid utf8=',     IsValidUtf8(res)])
      else
        ConsoleWrite(res);
    finally
      main.Free;
    end;
  except
    on E: Exception do
      ConsoleShowFatalException(E);
  end;
  // optional timing output
  if verbose then
  begin
    QueryPerformanceMicroSeconds(stop);
    dec(stop, start);
    ConsoleWrite(['done in ', MicroSecToString(stop), ' ',
      KB((FileSize(fn) * 1000000) div stop), '/s']);
  end;
end.

