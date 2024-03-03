unit Generate.Common;

{$mode ObjFPC}{$H+}

interface

uses
  Classes, SysUtils, streamex;

const
  cSeed: Longint = 46668267; // '1BRC' in ASCII
  cColdestTemp = -99.9;
  cHottestTemp = 99.9;

type
  { TGenerator }
  TGenerator = class(TObject)
  private
    FInputFile: String;
    FOutPutFile: String;
    FLineCount: Int64;
    FStationNames: TStringList;

    procedure BuildStationNames;
    function GenerateProgressBar(APercent: Integer): String;
  protected
  public
    constructor Create(AInputFile, AOutputFile: String; ALineCount: Int64);
    destructor Destroy; override;

    procedure Generate;
  published
  end;

implementation

uses
  Math,
  bufstream;

const
  batchPercent = 10;

  { TGenerator }

constructor TGenerator.Create(AInputFile, AOutputFile: String; ALineCount: Int64);
begin
  FInputFile := AInputFile;
  FOutPutFile := AOutputFile;
  FLineCount := ALineCount;

  FStationNames := TStringList.Create;
  FStationNames.Duplicates := dupIgnore;
  FStationNames.Sorted := True;
end;

destructor TGenerator.Destroy;
begin
  FStationNames.Free;
  inherited Destroy;
end;

procedure TGenerator.BuildStationNames;
var
  inputStream: TFileStream;
  streamReader: TStreamReader;
  entry: String;
  Count: Int64 = 0;
begin
  //WriteLn('Reading "',FInputFile,'"');
  // Load the Weather Station names
  if FileExists(FInputFile) then
  begin
    inputStream := TFileStream.Create(FInputFile, fmOpenRead);
    try
      streamReader := TStreamReader.Create(inputStream);
      try
        while not streamReader.EOF do
        begin
          entry := streamReader.ReadLine;
          if entry[1] <> '#' then
          begin
            entry := entry.Split(';')[0];
            FStationNames.Add(entry);
            //WriteLn('Got: ', entry);
            Inc(Count);
          end;
        end;
      finally
        streamReader.Free;
      end;
    finally
      inputStream.Free;
    end;
  end
  else
  begin
    raise Exception.Create(Format('File "%s" not found.', [FInputFile]));
  end;
end;

function TGenerator.GenerateProgressBar(APercent: Integer): String;
begin
  Result := '[';
  Result := Result + StringOfChar('#', APercent div 2);
  Result := Result + StringOfChar('-', 50 - (APercent div 2));
  Result := Result + Format('] %d %% done.', [APercent]);
end;

procedure TGenerator.Generate;
var
  index, pbpos, nextpb: Int64;
  stationId: Int64;
  randomTemp: Integer;
  outputFileStream: TFileStream;
  outputBufWriter: TWriteBufStream;
  line: String;
  rt: String[4];
  dt: TDateTime;
begin
  // Randomize sets this variable depending on the current time
  // We just set it to our own value
  RandSeed := cSeed;

  // Build list of station names
  BuildStationNames;

  dt := Now;

  outputFileStream := TFileStream.Create(FOutPutFile, fmCreate);

  pbpos := 0;

  try
    outputBufWriter := TWriteBufStream.Create(outputFileStream, 20 * 1024 * 1024);
    try
      Write(GenerateProgressBar(pbpos), #13);
      nextpb := floor(FLineCount * (pbpos + 1) / 100);
      // Generate the file
      line := '';
      for index := 1 to FLineCount do
      begin
        stationId := Random(FStationNames.Count);
        randomTemp := Random(1000);
        rt := IntToStr(randomTemp);
        case Ord(rt[0]) of
          1: rt := '0.' + rt;
          2: rt := rt[1] + '.' + rt[2];
          3: rt := rt[1] + rt[2] + '.' + rt[3];
          4: rt := rt[1] + rt[2] + rt[3] + '.' + rt[4];
        end;
        if (randomTemp <> 0) and (Random(2) = 1) then
          rt := '-' + rt;
        line := line + FStationNames[stationId] + ';' + rt + #13#10;
        if index mod 5000 = 0 then
        begin
          outputFileStream.WriteBuffer(line[1], Length(line));
          line := '';
        end;
        if index = nextpb then
        begin
          Inc(pbpos);
          Write(GenerateProgressBar(pbpos), #13);
          nextpb := floor(FLineCount * (pbpos + 1) / 100);
        end;
      end;
      if line <> '' then
        outputFileStream.WriteBuffer(line[1], Length(line));
    finally
      outputBufWriter.Free;
    end;
  finally
    outputFileStream.Free;
  end;
  WriteLn;                          
  WriteLn('Elapsed time: ', FormatDateTime('n" minutes "s" seconds"', Now - dt));
end;

end.
