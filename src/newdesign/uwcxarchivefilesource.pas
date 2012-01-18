unit uWcxArchiveFileSource;

{$mode objfpc}{$H+}
{$include calling.inc}

interface

uses
  Classes, SysUtils, contnrs, syncobjs, StringHashList, uOSUtils,
  WcxPlugin, uWCXmodule, uFile, uFileSourceProperty, uFileSourceOperationTypes,
  uArchiveFileSource, uFileProperty, uFileSource, uFileSourceOperation;

type

  TWcxArchiveFileSourceConnection = class;

  { IWcxArchiveFileSource }

  IWcxArchiveFileSource = interface(IArchiveFileSource)
    ['{DB32E8A8-486B-4053-9448-4C145C1A33FA}']

    function GetArcFileList: TObjectList;
    function GetPluginCapabilities: PtrInt;
    function GetWcxModule: TWcxModule;

    property ArchiveFileList: TObjectList read GetArcFileList;
    property PluginCapabilities: PtrInt read GetPluginCapabilities;
    property WcxModule: TWCXModule read GetWcxModule;
  end;

  { TWcxArchiveFileSource }

  TWcxArchiveFileSource = class(TArchiveFileSource, IWcxArchiveFileSource)
  private
    FModuleFileName: String;
    FPluginCapabilities: PtrInt;
    FArcFileList : TObjectList;
    FWcxModule: TWCXModule;
    FOpenResult: LongInt;

    function LoadModule: Boolean;
    procedure UnloadModule;
    procedure SetCryptCallback;
    function ReadArchive: Boolean;

    function GetArcFileList: TObjectList;
    function GetPluginCapabilities: PtrInt;
    function GetWcxModule: TWcxModule;

    function CreateConnection: TFileSourceConnection;
    procedure CreateConnections;

    procedure AddToConnectionQueue(Operation: TFileSourceOperation);
    procedure RemoveFromConnectionQueue(Operation: TFileSourceOperation);
    procedure AddConnection(Connection: TFileSourceConnection);
    procedure RemoveConnection(Connection: TFileSourceConnection);

    {en
       Searches connections list for a connection assigned to operation.
    }
    function FindConnectionByOperation(operation: TFileSourceOperation): TFileSourceConnection; virtual;

    procedure NotifyNextWaitingOperation(allowedOps: TFileSourceOperationTypes);

    procedure ClearCurrentOperation(Operation: TFileSourceOperation);

  protected
    procedure OperationFinished(Operation: TFileSourceOperation); override;

    function GetSupportedFileProperties: TFilePropertiesTypes; override;
    function SetCurrentWorkingDirectory(NewDir: String): Boolean; override;

    procedure DoReload(const PathsToReload: TPathsArray); override;

  public
    constructor Create(anArchiveFileSource: IFileSource;
                       anArchiveFileName: String;
                       aWcxPluginFileName: String;
                       aWcxPluginCapabilities: PtrInt); reintroduce;
    constructor Create(anArchiveFileSource: IFileSource;
                       anArchiveFileName: String;
                       aWcxPluginModule: TWcxModule;
                       aWcxPluginCapabilities: PtrInt); reintroduce;
    destructor Destroy; override;

    class function CreateFile(const APath: String; WcxHeader: TWCXHeader): TFile; overload;

    // Retrieve operations permitted on the source.  = capabilities?
    function GetOperationsTypes: TFileSourceOperationTypes; override;

    // Retrieve some properties of the file source.
    function GetProperties: TFileSourceProperties; override;

    // These functions create an operation object specific to the file source.
    function CreateListOperation(TargetPath: String): TFileSourceOperation; override;
    function CreateCopyInOperation(SourceFileSource: IFileSource;
                                   var SourceFiles: TFiles;
                                   TargetPath: String): TFileSourceOperation; override;
    function CreateCopyOutOperation(TargetFileSource: IFileSource;
                                    var SourceFiles: TFiles;
                                    TargetPath: String): TFileSourceOperation; override;
    function CreateDeleteOperation(var FilesToDelete: TFiles): TFileSourceOperation; override;
    function CreateExecuteOperation(var ExecutableFile: TFile;
                                    BasePath, Verb: String): TFileSourceOperation; override;
    function CreateTestArchiveOperation(var theSourceFiles: TFiles): TFileSourceOperation; override;
    function CreateCalcStatisticsOperation(var theFiles: TFiles): TFileSourceOperation; override;

    class function CreateByArchiveSign(anArchiveFileSource: IFileSource;
                                       anArchiveFileName: String): IWcxArchiveFileSource;
    class function CreateByArchiveType(anArchiveFileSource: IFileSource;
                                       anArchiveFileName: String;
                                       anArchiveType: String): IWcxArchiveFileSource;
    class function CreateByArchiveName(anArchiveFileSource: IFileSource;
                                       anArchiveFileName: String): IWcxArchiveFileSource;
    {en
       Returns @true if there is a plugin registered for the archive type
       (only extension is checked).
    }
    class function CheckPluginByExt(anArchiveType: String): Boolean;

    function GetConnection(Operation: TFileSourceOperation): TFileSourceConnection; override;
    procedure RemoveOperationFromQueue(Operation: TFileSourceOperation); override;

    property ArchiveFileList: TObjectList read FArcFileList;
    property PluginCapabilities: PtrInt read FPluginCapabilities;
    property WcxModule: TWCXModule read FWcxModule;
  end;

  { TWcxArchiveFileSourceConnection }

  TWcxArchiveFileSourceConnection = class(TFileSourceConnection)
  private
    FWcxModule: TWCXModule;

  public
    constructor Create(aWcxModule: TWCXModule); reintroduce;

    property WcxModule: TWCXModule read FWcxModule;
  end;

  EModuleNotLoadedException = class(EFileSourceException);

implementation

uses
  LCLProc, uDebug, uDCUtils, uGlobs,
  uDateTimeUtils,
  FileUtil, uCryptProc,
  uWcxArchiveListOperation,
  uWcxArchiveCopyInOperation,
  uWcxArchiveCopyOutOperation,
  uWcxArchiveDeleteOperation,
  uWcxArchiveExecuteOperation,
  uWcxArchiveTestArchiveOperation,
  uWcxArchiveCalcStatisticsOperation;

const
  connCopyIn      = 0;
  connCopyOut     = 1;
  connDelete      = 2;
  connTestArchive = 3;

var
  // Always use appropriate lock to access these lists.
  WcxConnections: TObjectList; // store connections created by Wcx file sources
  WcxOperationsQueue: TObjectList; // store queued operations, use only under FOperationsQueueLock
  WcxConnectionsLock: TCriticalSection; // used to synchronize access to connections
  WcxOperationsQueueLock: TCriticalSection; // used to synchronize access to operations queue

function CryptProc(CryptoNumber: Integer; Mode: Integer; ArchiveName: UTF8String; var Password: UTF8String): Integer;
const
  cPrefix = 'wcx';
var
  sGroup,
  sPassword: AnsiString;
begin
  try
    sGroup:= ExtractOnlyFileExt(ArchiveName);
    case Mode of
    PK_CRYPT_SAVE_PASSWORD:
      begin
        if PasswordStore.WritePassword(cPrefix, sGroup, ArchiveName, Password) then
          Result:= E_SUCCESS
        else
          Result:= E_EWRITE;
      end;
    PK_CRYPT_LOAD_PASSWORD,
    PK_CRYPT_LOAD_PASSWORD_NO_UI:
      begin
        Result:= E_EREAD;
        if (Mode = PK_CRYPT_LOAD_PASSWORD_NO_UI) and (PasswordStore.HasMasterKey = False) then
          Exit(E_NO_FILES);
        if PasswordStore.ReadPassword(cPrefix, sGroup, ArchiveName, Password) then
          Result:= E_SUCCESS;
      end;
    PK_CRYPT_COPY_PASSWORD,
    PK_CRYPT_MOVE_PASSWORD:
      begin
        Result:= E_EREAD;
        if PasswordStore.ReadPassword(cPrefix, sGroup, ArchiveName, sPassword) then
          begin
            if not PasswordStore.WritePassword(cPrefix, sGroup, Password, sPassword) then
              Exit(E_EWRITE);
            if Mode = PK_CRYPT_MOVE_PASSWORD then
              PasswordStore.DeletePassword(cPrefix, sGroup, ArchiveName);
            Result:= E_SUCCESS;
          end;
      end;
    PK_CRYPT_DELETE_PASSWORD:
      begin
        PasswordStore.DeletePassword(cPrefix, sGroup, ArchiveName);
        Result:= E_SUCCESS;
      end;
    end;
  except
    Result:= E_ECREATE;
  end;
end;

function CryptProcA(CryptoNumber: Integer; Mode: Integer; ArchiveName, Password: PAnsiChar; MaxLen: Integer): Integer; dcpcall;
var
  sArchiveName,
  sPassword: UTF8String;
begin
  sArchiveName:= SysToUTF8(StrPas(ArchiveName));
  sPassword:= SysToUTF8(StrPas(Password));
  Result:= CryptProc(CryptoNumber, Mode, sArchiveName, sPassword);
  if Result = E_SUCCESS then
    begin
      if Password <> nil then
        StrPLCopy(Password, UTF8ToSys(sPassword), MaxLen);
    end;
end;

function CryptProcW(CryptoNumber: Integer; Mode: Integer; ArchiveName, Password: PWideChar; MaxLen: Integer): Integer; dcpcall;
var
  sArchiveName,
  sPassword: UTF8String;
begin
  sArchiveName:= UTF8Encode(WideString(ArchiveName));
  sPassword:= UTF8Encode(WideString(Password));
  Result:= CryptProc(CryptoNumber, Mode, sArchiveName, sPassword);
  if Result = E_SUCCESS then
    begin
      if Password <> nil then
        StrPLCopyW(Password, UTF8Decode(sPassword), MaxLen);
    end;
end;

//--------------------------------------------------------------------------------------------------

class function TWcxArchiveFileSource.CreateByArchiveSign(
    anArchiveFileSource: IFileSource;
    anArchiveFileName: String): IWcxArchiveFileSource;
var
  I: Integer;
  ModuleFileName: String;
  WcxPlugin: TWcxModule;
  bFound: Boolean = False;
  hArchive: TArcHandle;
  lOpenResult: LongInt;
begin
  Result := nil;

  WcxPlugin:= TWcxModule.Create;

  // Check if there is a registered plugin for the archive file by content.
  for I := 0 to gWCXPlugins.Count - 1 do
  begin
    if (gWCXPlugins.Enabled[I]) then
    begin
      ModuleFileName := GetCmdDirFromEnvVar(gWCXPlugins.FileName[I]);

      if WcxPlugin.LoadModule(ModuleFileName) then
        begin
          if Assigned(WcxPlugin.CanYouHandleThisFileW) or Assigned(WcxPlugin.CanYouHandleThisFile) then
            begin
              bFound:= WcxPlugin.WcxCanYouHandleThisFile(anArchiveFileName);
              if bFound then Break;
            end
          else if ((gWCXPlugins.Flags[I] and PK_CAPS_BY_CONTENT) = PK_CAPS_BY_CONTENT) then
            begin
              hArchive:= WcxPlugin.OpenArchiveHandle(anArchiveFileName, PK_OM_LIST, lOpenResult);
              if (hArchive <> 0) and (lOpenResult = E_SUCCESS) then
                begin
                  WcxPlugin.CloseArchive(hArchive);
                  bFound:= True;
                  Break;
                end;
            end
          else if ((gWCXPlugins.Flags[I] and PK_CAPS_HIDE) = PK_CAPS_HIDE) then
            begin
              bFound:= SameText(ExtractOnlyFileExt(anArchiveFileName), gWCXPlugins.Ext[I]);
              if bFound then Break;
            end;
          WcxPlugin.UnloadModule;
        end;
    end;
  end;
  if not bFound then
    WcxPlugin.Free
  else
    begin
      Result := TWcxArchiveFileSource.Create(anArchiveFileSource,
                                             anArchiveFileName,
                                             WcxPlugin,
                                             gWCXPlugins.Flags[I]);

      DCDebug('Found registered plugin ' + ModuleFileName + ' for archive ' + anArchiveFileName);
    end;
end;

class function TWcxArchiveFileSource.CreateByArchiveType(
    anArchiveFileSource: IFileSource;
    anArchiveFileName: String;
    anArchiveType: String): IWcxArchiveFileSource;
var
  i: Integer;
  ModuleFileName: String;
begin
  Result := nil;

  // Check if there is a registered plugin for the extension of the archive file name.
  for i := 0 to gWCXPlugins.Count - 1 do
  begin
    if SameText(anArchiveType, gWCXPlugins.Ext[i]) and (gWCXPlugins.Enabled[i]) and
       ((gWCXPlugins.Flags[I] and PK_CAPS_HIDE) <> PK_CAPS_HIDE) then
    begin
      ModuleFileName := GetCmdDirFromEnvVar(gWCXPlugins.FileName[I]);

      Result := TWcxArchiveFileSource.Create(anArchiveFileSource,
                                             anArchiveFileName,
                                             ModuleFileName,
                                             gWCXPlugins.Flags[I]);

      DCDebug('Found registered plugin ' + ModuleFileName + ' for archive ' + anArchiveFileName);
      break;
    end;
  end;
end;

class function TWcxArchiveFileSource.CreateByArchiveName(
    anArchiveFileSource: IFileSource;
    anArchiveFileName: String): IWcxArchiveFileSource;
begin
  Result:= CreateByArchiveType(anArchiveFileSource, anArchiveFileName,
                               ExtractOnlyFileExt(anArchiveFileName));
end;

class function TWcxArchiveFileSource.CheckPluginByExt(anArchiveType: String): Boolean;
var
  i: Integer;
begin
  for i := 0 to gWCXPlugins.Count - 1 do
  begin
    if SameText(anArchiveType, gWCXPlugins.Ext[i]) and (gWCXPlugins.Enabled[i]) then
      Exit(True);
  end;
  Result := False;
end;

// ----------------------------------------------------------------------------

constructor TWcxArchiveFileSource.Create(anArchiveFileSource: IFileSource;
                                         anArchiveFileName: String;
                                         aWcxPluginFileName: String;
                                         aWcxPluginCapabilities: PtrInt);
begin
  inherited Create(anArchiveFileSource, anArchiveFileName);

  FModuleFileName := aWcxPluginFileName;
  FPluginCapabilities := aWcxPluginCapabilities;
  FArcFileList := TObjectList.Create(True);
  FWcxModule := TWCXModule.Create;

  if LoadModule = False then
    raise EModuleNotLoadedException.Create('Cannot load WCX module ' + FModuleFileName);

  FOperationsClasses[fsoCopyIn]          := TWcxArchiveCopyInOperation.GetOperationClass;
  FOperationsClasses[fsoCopyOut]         := TWcxArchiveCopyOutOperation.GetOperationClass;

  SetCryptCallback;

  if mbFileExists(anArchiveFileName) then
  begin
    if not ReadArchive then
      raise Exception.Create(GetErrorMsg(FOpenResult));
  end;

  CreateConnections;
end;

constructor TWcxArchiveFileSource.Create(anArchiveFileSource: IFileSource;
                                         anArchiveFileName: String;
                                         aWcxPluginModule: TWcxModule;
                                         aWcxPluginCapabilities: PtrInt);
begin
  inherited Create(anArchiveFileSource, anArchiveFileName);

  FPluginCapabilities := aWcxPluginCapabilities;
  FArcFileList := TObjectList.Create(True);
  FWcxModule := aWcxPluginModule;

  FOperationsClasses[fsoCopyIn]          := TWcxArchiveCopyInOperation.GetOperationClass;
  FOperationsClasses[fsoCopyOut]         := TWcxArchiveCopyOutOperation.GetOperationClass;

  SetCryptCallback;

  if mbFileExists(anArchiveFileName) then
  begin
    if not ReadArchive then
      raise Exception.Create(GetErrorMsg(FOpenResult));
  end;

  CreateConnections;
end;

destructor TWcxArchiveFileSource.Destroy;
begin
  UnloadModule;

  inherited;

  if Assigned(FArcFileList) then
    FreeAndNil(FArcFileList);
  if Assigned(FWcxModule) then
    FreeAndNil(FWcxModule);
end;

class function TWcxArchiveFileSource.CreateFile(const APath: String; WcxHeader: TWCXHeader): TFile;
begin
  Result := TFile.Create(APath);

  with Result do
  begin
    {
      FileCRC,
      CompressionMethod,
      Comment,
    }
    AttributesProperty := {TNtfsFileAttributesProperty or Unix?}
                          TFileAttributesProperty.CreateOSAttributes(WcxHeader.FileAttr);
    if AttributesProperty.IsDirectory then
      begin
        SizeProperty := TFileSizeProperty.Create(0);
        CompressedSizeProperty := TFileCompressedSizeProperty.Create(0);
      end
    else
      begin
        SizeProperty := TFileSizeProperty.Create(WcxHeader.UnpSize);
        CompressedSizeProperty := TFileCompressedSizeProperty.Create(WcxHeader.PackSize);
      end;
    ModificationTimeProperty := TFileModificationDateTimeProperty.Create(0);
    try
      ModificationTime := WcxFileTimeToDateTime(WcxHeader);
    except
      on EConvertError do;
    end;

    // Set name after assigning Attributes property, because it is used to get extension.
    Name := ExtractFileName(WcxHeader.FileName);
  end;
end;

function TWcxArchiveFileSource.GetOperationsTypes: TFileSourceOperationTypes;
begin
  Result := [fsoList, fsoCopyOut, fsoTestArchive, fsoExecute, fsoCalcStatistics]; // by default
  with FWcxModule do
  begin
    if (((FPluginCapabilities and PK_CAPS_NEW) <> 0) or ((FPluginCapabilities and PK_CAPS_MODIFY) <> 0)) and
       (Assigned(PackFiles) or Assigned(PackFilesW)) then
      Result:= Result + [fsoCopyIn];
    if ((FPluginCapabilities and PK_CAPS_DELETE) <> 0) and
       (Assigned(DeleteFiles) or Assigned(DeleteFilesW)) then
      Result:= Result + [fsoDelete];
  end;
end;

function TWcxArchiveFileSource.GetProperties: TFileSourceProperties;
begin
  Result := [fspUsesConnections];
end;

function TWcxArchiveFileSource.GetSupportedFileProperties: TFilePropertiesTypes;
begin
  Result := inherited GetSupportedFileProperties;
end;

function TWcxArchiveFileSource.SetCurrentWorkingDirectory(NewDir: String): Boolean;
var
  I: Integer;
  Header: TWCXHeader;
begin
  Result := False;
  if Length(NewDir) > 0 then
  begin
    if NewDir = GetRootDir() then
      Exit(True);

    NewDir := IncludeTrailingPathDelimiter(NewDir);

    // Search file list for a directory with name NewDir.
    for I := 0 to FArcFileList.Count - 1 do
    begin
      Header := TWCXHeader(FArcFileList.Items[I]);
      if FPS_ISDIR(Header.FileAttr) and (Length(Header.FileName) > 0) then
      begin
        if NewDir = IncludeTrailingPathDelimiter(GetRootDir() + Header.FileName) then
          Exit(True);
      end;
    end;
  end;
end;

function TWcxArchiveFileSource.LoadModule: Boolean;
begin
  Result := WcxModule.LoadModule(FModuleFileName);
end;

procedure TWcxArchiveFileSource.UnloadModule;
begin
  WcxModule.UnloadModule;
end;

procedure TWcxArchiveFileSource.SetCryptCallback;
var
  iFlags: Integer;
begin
  if not PasswordStore.HasMasterKey then
    iFlags:= 0
  else
    iFlags:= PK_CRYPTOPT_MASTERPASS_SET;

  FWcxModule.WcxSetCryptCallback(0, iFlags, @CryptProcA, @CryptProcW);
end;

function TWcxArchiveFileSource.GetArcFileList: TObjectList;
begin
  Result := FArcFileList;
end;

function TWcxArchiveFileSource.GetPluginCapabilities: PtrInt;
begin
  Result := FPluginCapabilities;
end;

function TWcxArchiveFileSource.GetWcxModule: TWcxModule;
begin
  Result := FWcxModule;
end;

function TWcxArchiveFileSource.CreateListOperation(TargetPath: String): TFileSourceOperation;
var
  TargetFileSource: IFileSource;
begin
  TargetFileSource := Self;
  Result := TWcxArchiveListOperation.Create(TargetFileSource, TargetPath);
end;

function TWcxArchiveFileSource.CreateCopyInOperation(
            SourceFileSource: IFileSource;
            var SourceFiles: TFiles;
            TargetPath: String): TFileSourceOperation;
var
  TargetFileSource: IFileSource;
begin
  TargetFileSource := Self;
  Result := TWcxArchiveCopyInOperation.Create(SourceFileSource,
                                              TargetFileSource,
                                              SourceFiles, TargetPath);
end;

function TWcxArchiveFileSource.CreateCopyOutOperation(
            TargetFileSource: IFileSource;
            var SourceFiles: TFiles;
            TargetPath: String): TFileSourceOperation;
var
  SourceFileSource: IFileSource;
begin
  SourceFileSource := Self;
  Result := TWcxArchiveCopyOutOperation.Create(SourceFileSource,
                                               TargetFileSource,
                                               SourceFiles, TargetPath);
end;

function TWcxArchiveFileSource.CreateDeleteOperation(var FilesToDelete: TFiles): TFileSourceOperation;
var
  TargetFileSource: IFileSource;
begin
  TargetFileSource := Self;
  Result := TWcxArchiveDeleteOperation.Create(TargetFileSource,
                                              FilesToDelete);
end;

function TWcxArchiveFileSource.CreateExecuteOperation(var ExecutableFile: TFile;
                                                      BasePath, Verb: String): TFileSourceOperation;
var
  TargetFileSource: IFileSource;
begin
  TargetFileSource := Self;
  Result:=  TWcxArchiveExecuteOperation.Create(TargetFileSource, ExecutableFile, BasePath, Verb);
end;

function TWcxArchiveFileSource.CreateTestArchiveOperation(var theSourceFiles: TFiles): TFileSourceOperation;
var
  SourceFileSource: IFileSource;
begin
  SourceFileSource := Self;
  Result:=  TWcxArchiveTestArchiveOperation.Create(SourceFileSource, theSourceFiles);
end;

function TWcxArchiveFileSource.CreateCalcStatisticsOperation(
  var theFiles: TFiles): TFileSourceOperation;
var
  TargetFileSource: IFileSource;
begin
  TargetFileSource := Self;
  Result := TWcxArchiveCalcStatisticsOperation.Create(TargetFileSource, theFiles);
end;

function TWcxArchiveFileSource.ReadArchive: Boolean;

  procedure CollectDirs(Path: PAnsiChar; var DirsList: TStringHashList);
  var
    I : Integer;
    Dir : AnsiString;
  begin
    // Scan from the second char from the end, to the second char from the beginning.
    for I := strlen(Path) - 2 downto 1 do
    begin
      if Path[I] = PathDelim then
      begin
        SetString(Dir, Path, I);
        if DirsList.Find(Dir) = -1 then
          // Add directory and continue scanning for parent directories.
          DirsList.Add(Dir)
        else
          // This directory is already in the list and we assume
          // that all parent directories are too.
          Exit;
      end
    end;
  end;

var
  ArcHandle : TArcHandle;
  Header: TWCXHeader;
  AllDirsList, ExistsDirList : TStringHashList;
  I : Integer;
  NameLength: Integer;
begin
  Result:= False;

  if not mbFileAccess(ArchiveFileName, fmOpenRead) then
  begin
    FOpenResult := E_EREAD;
    Exit;
  end;

  DCDebug('Open Archive');

  (*Open Archive*)
  ArcHandle := WcxModule.OpenArchiveHandle(ArchiveFileName, PK_OM_LIST, FOpenResult);
  if ArcHandle = 0 then Exit;

  WcxModule.WcxSetChangeVolProc(ArcHandle, nil, nil {ChangeVolProc});
  WcxModule.WcxSetProcessDataProc(ArcHandle, nil, nil {ProcessDataProc});

  DCDebug('Get File List');
  (*Get File List*)
  FArcFileList.Clear;
  ExistsDirList := TStringHashList.Create(True);
  AllDirsList := TStringHashList.Create(True);

  try
    while (WcxModule.ReadWCXHeader(ArcHandle, Header) = E_SUCCESS) do
      begin
        // Some plugins end directories with path delimiter. Delete it if present.
        if FPS_ISDIR(Header.FileAttr) then
        begin
          NameLength := Length(Header.FileName);
          if (Header.FileName[NameLength] = PathDelim) then
            Delete(Header.FileName, NameLength, 1);

        //****************************
        (* Workaround for plugins that don't give a list of folders
           or the list does not include all of the folders. *)

          // Collect directories that the plugin supplies.
          if (ExistsDirList.Find(Header.FileName) < 0) then
            ExistsDirList.Add(Header.FileName);
        end;

        // Collect all directories.
        CollectDirs(PAnsiChar(Header.FileName), AllDirsList);

        //****************************

        FArcFileList.Add(Header);

        // get next file
        FOpenResult := WcxModule.WcxProcessFile(ArcHandle, PK_SKIP, EmptyStr, EmptyStr);

        // Check for errors
        if FOpenResult <> E_SUCCESS then Exit;
      end; // while

      (* if plugin does not give a list of folders *)
      for I := 0 to AllDirsList.Count - 1 do
      begin
        // Add only those directories that were not supplied by the plugin.
        if ExistsDirList.Find(AllDirsList.List[I]^.Key) < 0 then
        begin
          Header := TWCXHeader.Create;
          try
            Header.FileName := AllDirsList.List[I]^.Key;
            Header.ArcName  := ArchiveFileName;
            Header.FileAttr := faFolder;
{$IFDEF MSWINDOWS}
            WinToDosTime(mbFileAge(ArchiveFileName), Header.FileTime);
{$ELSE}
{$PUSH}{$R-}
            Header.FileTime := LongInt(mbFileAge(ArchiveFileName));
{$POP}
{$ENDIF}
            FArcFileList.Add(Header);
          except
            FreeAndNil(Header);
          end;
        end;
      end;

    Result:= True;
  finally
    AllDirsList.Free;
    ExistsDirList.Free;
    WcxModule.CloseArchive(ArcHandle);
  end;
end;

procedure TWcxArchiveFileSource.AddToConnectionQueue(Operation: TFileSourceOperation);
begin
  WcxOperationsQueueLock.Acquire;
  try
    if WcxOperationsQueue.IndexOf(Operation) < 0 then
      WcxOperationsQueue.Add(Operation);
  finally
    WcxOperationsQueueLock.Release;
  end;
end;

procedure TWcxArchiveFileSource.RemoveFromConnectionQueue(Operation: TFileSourceOperation);
begin
  WcxOperationsQueueLock.Acquire;
  try
    WcxOperationsQueue.Remove(Operation);
  finally
    WcxOperationsQueueLock.Release;
  end;
end;

procedure TWcxArchiveFileSource.AddConnection(Connection: TFileSourceConnection);
begin
  WcxConnectionsLock.Acquire;
  try
    if WcxConnections.IndexOf(Connection) < 0 then
      WcxConnections.Add(Connection);
  finally
    WcxConnectionsLock.Release;
  end;
end;

procedure TWcxArchiveFileSource.RemoveConnection(Connection: TFileSourceConnection);
begin
  WcxConnectionsLock.Acquire;
  try
    WcxConnections.Remove(Connection);
  finally
    WcxConnectionsLock.Release;
  end;
end;

function TWcxArchiveFileSource.GetConnection(Operation: TFileSourceOperation): TFileSourceConnection;
begin
  Result := nil;
  case Operation.ID of
    fsoCopyIn:
      Result := WcxConnections[connCopyIn] as TFileSourceConnection;
    fsoCopyOut:
      Result := WcxConnections[connCopyOut] as TFileSourceConnection;
    fsoDelete:
      Result := WcxConnections[connDelete] as TFileSourceConnection;
    fsoTestArchive:
      Result := WcxConnections[connTestArchive] as TFileSourceConnection;
    else
      begin
        Result := CreateConnection;
        if Assigned(Result) then
          AddConnection(Result);
      end;
  end;

  if Assigned(Result) then
    Result := TryAcquireConnection(Result, Operation);

  // No available connection - wait.
  if not Assigned(Result) then
    AddToConnectionQueue(Operation)
  else
    // Connection acquired.
    // The operation may have been waiting in the queue
    // for the connection, so remove it from the queue.
    RemoveFromConnectionQueue(Operation);
end;

procedure TWcxArchiveFileSource.RemoveOperationFromQueue(Operation: TFileSourceOperation);
begin
  RemoveFromConnectionQueue(Operation);
end;

function TWcxArchiveFileSource.CreateConnection: TFileSourceConnection;
begin
  Result := TWcxArchiveFileSourceConnection.Create(FWcxModule);
end;

procedure TWcxArchiveFileSource.CreateConnections;
begin
  WcxConnectionsLock.Acquire;
  try
    if WcxConnections.Count = 0 then
    begin
      // Reserve some connections (only once).
      WcxConnections.Add(CreateConnection); // connCopyIn
      WcxConnections.Add(CreateConnection); // connCopyOut
      WcxConnections.Add(CreateConnection); // connDelete
      WcxConnections.Add(CreateConnection); // connTestArchive
    end;
  finally
    WcxConnectionsLock.Release;
  end;
end;

function TWcxArchiveFileSource.FindConnectionByOperation(operation: TFileSourceOperation): TFileSourceConnection;
var
  i: Integer;
  connection: TFileSourceConnection;
begin
  Result := nil;
  WcxConnectionsLock.Acquire;
  try
    for i := 0 to WcxConnections.Count - 1 do
    begin
      connection := WcxConnections[i] as TFileSourceConnection;
      if connection.AssignedOperation = operation then
        Exit(connection);
    end;
  finally
    WcxConnectionsLock.Release;
  end;
end;

procedure TWcxArchiveFileSource.OperationFinished(Operation: TFileSourceOperation);
var
  allowedIDs: TFileSourceOperationTypes = [];
  connection: TFileSourceConnection;
begin
  ClearCurrentOperation(Operation);

  connection := FindConnectionByOperation(Operation);
  if Assigned(connection) then
  begin
    connection.Release; // unassign operation

    WcxConnectionsLock.Acquire;
    try
      // If there are operations waiting, take the first one and notify
      // that a connection is available.
      // Only check operation types for which there are reserved connections.
      if Operation.ID in [fsoCopyIn, fsoCopyOut, fsoDelete, fsoTestArchive] then
      begin
        Include(allowedIDs, Operation.ID);
        NotifyNextWaitingOperation(allowedIDs);
      end
      else
      begin
        WcxConnections.Remove(connection);
      end;

    finally
      WcxConnectionsLock.Release;
    end;
  end;
end;

procedure TWcxArchiveFileSource.NotifyNextWaitingOperation(allowedOps: TFileSourceOperationTypes);
var
  i: Integer;
  operation: TFileSourceOperation;
begin
  WcxOperationsQueueLock.Acquire;
  try
    for i := 0 to WcxOperationsQueue.Count - 1 do
    begin
      operation := WcxOperationsQueue.Items[i] as TFileSourceOperation;
      if (operation.State = fsosWaitingForConnection) and
         (operation.ID in allowedOps) then
      begin
        operation.ConnectionAvailableNotify;
        Exit;
      end;
    end;
  finally
    WcxOperationsQueueLock.Release;
  end;
end;

procedure TWcxArchiveFileSource.ClearCurrentOperation(Operation: TFileSourceOperation);
begin
  case Operation.ID of
    fsoCopyIn:
      TWcxArchiveCopyInOperation.ClearCurrentOperation;
    fsoCopyOut:
      TWcxArchiveCopyOutOperation.ClearCurrentOperation;
    fsoDelete:
      TWcxArchiveDeleteOperation.ClearCurrentOperation;
    fsoTestArchive:
      TWcxArchiveTestArchiveOperation.ClearCurrentOperation;
  end;
end;

procedure TWcxArchiveFileSource.DoReload(const PathsToReload: TPathsArray);
begin
  ReadArchive;
end;

{ TWcxArchiveFileSourceConnection }

constructor TWcxArchiveFileSourceConnection.Create(aWcxModule: TWCXModule);
begin
  FWcxModule := aWcxModule;
  inherited Create;
end;

initialization
  WcxConnections := TObjectList.Create(True); // True = destroy objects when destroying list
  WcxConnectionsLock := TCriticalSection.Create;
  WcxOperationsQueue := TObjectList.Create(False); // False = don't destroy operations (only store references)
  WcxOperationsQueueLock := TCriticalSection.Create;

finalization
  FreeThenNil(WcxConnections);
  FreeThenNil(WcxConnectionsLock);
  FreeThenNil(WcxOperationsQueue);
  FreeThenNil(WcxOperationsQueueLock);

end.

