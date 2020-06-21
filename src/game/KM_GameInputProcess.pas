unit KM_GameInputProcess;
{$I KaM_Remake.inc}
interface
uses
  Generics.Collections,
  KM_Units, KM_UnitGroup,
  KM_Houses, KM_HouseWoodcutters, KM_Hand,
  KM_ResHouses, KM_ResWares, KM_ScriptingConsoleCommands,
  KM_CommonClasses, KM_CommonTypes, KM_Defaults, KM_Points, KM_WorkerThread,
  KM_HandTypes,
  KM_UnitGroupTypes;

{ A. This unit takes and adjoins players input from TGame and TGamePlayInterfaces clicks and keys
  Then passes it on to game events.
  E.g. there are 2 ways player can place an order to selected Warrior:
  1. Click on map
  2. Click on minimap

  B. And most important, it accumulates and feeds player input to the game.
  Thus making possible to:
   - record gameplay
   - playback replays
   - send input through LAN to make multiplayer games

  This is a polymorphic unit which is only used as the parent of TGameInputProcess_Single for single
  player or TGameInputProcess_Multi for multiplayer
  It contains a few common methods such as replays as well as abstract methods for the child classes to handle.
  Most importantly it converts all Cmd____ methods called by TGamePlayInterfaces into one procedure
  ProcessCommandFromPlayer. Single and Multi then use this according to their needs.
  Replays are stored and managed here, hidden from the child classes by private. They add new replay
  commands with StoreCommand, and in gipReplaying state commands are executed on Tick
  }

const
  MAX_PARAMS = 4; //There are maximum of 4 integers passed along with a command


type
  TKMGIPReplayState = (gipRecording, gipReplaying);

  TKMGameInputCommandType = (
    gicNone,
    //I.      Army commands, only warriors (TKMUnitWarrior, OrderInfo)
    gicArmyFeed,
    gicArmySplit,
    gicArmySplitSingle,
    gicArmyLink,
    gicArmyAttackUnit,
    gicArmyAttackHouse,
    gicArmyHalt,
    gicArmyFormation,    //Formation commands
    gicArmyWalk,         //Walking
    gicArmyStorm,        //StormAttack

    //II. Unit commands
    gicUnitDismiss,
    gicUnitDismissCancel,

    //III.     Building/road plans (what to build and where)
    gicBuildToggleFieldPlan,
    gicBuildRemoveFieldPlan, //Removal of a plan
    gicBuildRemoveHouse,     //Removal of house
    gicBuildRemoveHousePlan, //Removal of house plan
    gicBuildHousePlan,       //Build HouseType

    //IV.    House repair/delivery/orders (TKMHouse, Toggle(repair, delivery, orders))
    gicHouseRepairToggle,
    gicHouseDeliveryModeNext,
    gicHouseDeliveryModePrev,
    gicHouseClosedForWorkerTgl,      //Toggle house state for worker - vacate or occupy
    gicHouseOrderProduct,            //Place an order to manufacture warfare
    gicHouseMarketFrom,              //Select wares to trade in marketplace
    gicHouseMarketTo,                //Select wares to trade in marketplace
    gicHouseWoodcutterMode,          //Switch the woodcutter mode
    gicHouseArmorWSDeliveryToggle,   //Toggle resourse delivery to armor workshop
    gicHouseStoreNotAcceptFlag,      //Control wares delivery to store
    gicHStoreNotAllowTakeOutFlag,    //Control wares delivery from store
    gicHouseSchoolTrain,             //Place an order to train citizen
    gicHouseSchoolTrainChOrder,      //Change school training order
    gicHouseSchoolTrainChLastUOrder, //Change school training order for last unit in queue
    gicHouseBarracksAcceptFlag,      //Control wares delivery to barracks
    gicHBarracksNotAllowTakeOutFlag, //Control wares delivery from barracks
    gicHBarracksAcceptRecruitsTgl,   //Toggle are recruits allowed to enter barracks or not
    gicHouseBarracksEquip,           //Place an order to train warrior in the Barracks
    gicHouseBarracksRally,           //Set the rally point for the Barracks
    gicHouseTownHallEquip,           //Place an order to train warrior in the TownHall
    gicHouseTownHallRally,           //Set the rally point for the TownHall
    gicHouseTownHallMaxGold,         //Set TownHall MaxGold value
    gicHouseRemoveTrain,             //Remove unit being trained from School
    gicHouseWoodcuttersCutting,      //Set the cutting point for the Woodcutters

    //V.     Delivery ratios changes (and other game-global settings)
    gicWareDistributionChange,   //Change of distribution for 1 ware
    gicWareDistributions,        //Update distributions for all wares at ones

    //VI.      Game changes
    gicGameAlertBeacon,          //Signal alert (beacon)
    gicGamePause,
    gicGameSpeed,
    gicGameAutoSave,
    gicGameAutoSaveAfterPT,
    gicGameSaveReturnLobby,
    gicGameLoadSave,
    gicGameTeamChange,
    gicGameHotkeySet,        //Hotkeys are synced for MP saves (UI keeps local copy to avoid GIP delays)
    gicGameMessageLogRead,   //Player marks a message in their log as read
    gicGamePlayerChange,     //Players can be changed to AI when loading a save and player name could be changed
    gicGamePlayerDefeat,     //Player can be defeated after intentional quit from the game
    gicGamePlayerAllianceSet,//Set player alliance to other player
    gicGamePlayerAddDefGoals,//Set player default goals

    //VII.
    gicScriptConsoleCommand, //Script console command invokation
    gicScriptSoundRemoveRq,  //Request to remove script sound

    //VIII.     Temporary and debug commands
    gicTempAddScout,
    gicTempRevealMap, //Revealing the map can have an impact on the game. Events happen based on tiles being revealed
    gicTempVictory,
    gicTempDefeat,
    gicTempDoNothing  //Used for "aggressive" replays that store a command every tick

    { Optional input }
    //VI.     Viewport settings for replay (location, zoom)
    //VII.    Message queue handling in gameplay interface
    //IX.     Text messages for multiplayer (moved to Networking)
    );

  TKMGameInputCommandPackType = (
    gicpt_NoParams,
    gicpt_Int1,
    gicpt_Int2,
    gicpt_Int3,
    gicpt_Int4,
    gicpt_Ansi1Int2,
    gicpt_Float,
    gicpt_UniStr1,
    gicpt_Ansi1Uni4,
    gicpt_Date);

const
  BLOCKED_BY_PEACETIME: set of TKMGameInputCommandType = [gicArmySplit, gicArmySplitSingle,
    gicArmyLink, gicArmyAttackUnit, gicArmyAttackHouse, gicArmyHalt,
    gicArmyFormation,  gicArmyWalk, gicArmyStorm, gicHouseBarracksEquip, gicHouseTownHallEquip];

  ALLOWED_AFTER_DEFEAT: set of TKMGameInputCommandType =
    [gicGameAlertBeacon, gicGameSpeed, gicGameAutoSave, gicGameAutoSaveAfterPT, gicGameSaveReturnLobby, gicGameLoadSave,
     gicGameMessageLogRead, gicScriptSoundRemoveRq, gicTempDoNothing];

  ALLOWED_IN_CINEMATIC: set of TKMGameInputCommandType =
    [gicGameAlertBeacon, gicGameSpeed, gicGameAutoSave, gicGameAutoSaveAfterPT, gicGameSaveReturnLobby, gicGameMessageLogRead,
     gicGamePlayerAllianceSet, gicGamePlayerAddDefGoals, gicScriptSoundRemoveRq, gicTempDoNothing];

  ALLOWED_BY_SPECTATORS: set of TKMGameInputCommandType =
    [gicGameAlertBeacon, gicGameSpeed, gicGameAutoSave, gicGameAutoSaveAfterPT, gicGameSaveReturnLobby, gicGameLoadSave,
     gicGamePlayerDefeat, gicTempDoNothing];

  //Those commands should not have random check, because they they are not strictly happen, depends of player config and actions
  //We want to make it possible to reproduce AI city build knowing only seed + map config
  //Autosave and other commands random checks could break it, since every command have its own random check (and KaMRandom call)
  SKIP_RANDOM_CHECKS_FOR: set of TKMGameInputCommandType =
    [gicGameAlertBeacon, gicGameSpeed, gicGameAutoSave, gicGameAutoSaveAfterPT, gicGameSaveReturnLobby, gicGameLoadSave];

  ARMY_ORDER_COMMANDS: set of TKMGameInputCommandType = [
    gicArmyFeed,
    gicArmySplit,
    gicArmySplitSingle,
    gicArmyLink,
    gicArmyAttackUnit,
    gicArmyAttackHouse,
    gicArmyHalt,
    gicArmyFormation,
    gicArmyWalk,
    gicArmyStorm];

  HOUSE_ORDER_COMMANDS: set of TKMGameInputCommandType = [
    gicHouseRepairToggle,
    gicHouseDeliveryModeNext,
    gicHouseDeliveryModePrev,
    gicHouseClosedForWorkerTgl,
    gicHouseOrderProduct,
    gicHouseMarketFrom,
    gicHouseMarketTo,
    gicHouseWoodcutterMode,
    gicHouseStoreNotAcceptFlag,
    gicHouseSchoolTrain,
    gicHouseSchoolTrainChOrder,
    gicHouseSchoolTrainChLastUOrder,
    gicHouseBarracksAcceptFlag,
    gicHBarracksNotAllowTakeOutFlag,
    gicHBarracksAcceptRecruitsTgl,
    gicHouseBarracksEquip,
    gicHouseBarracksRally,
    gicHouseTownHallEquip,
    gicHouseTownHallRally,
    gicHouseTownHallMaxGold,
    gicHouseRemoveTrain,
    gicHouseWoodcuttersCutting];


  COMMAND_PACK_TYPES: array[TKMGameInputCommandType] of TKMGameInputCommandPackType = (
    gicpt_NoParams, // gicNone
    //I.      Army commands, only warriors (TKMUnitWarrior, OrderInfo)
    gicpt_Int1,     // gicArmyFeed
    gicpt_Int1,     // gicArmySplit
    gicpt_Int1,     // gicArmySplitSingle
    gicpt_Int2,     // gicArmyLink
    gicpt_Int2,     // gicArmyAttackUnit
    gicpt_Int2,     // gicArmyAttackHouse
    gicpt_Int1,     // gicArmyHalt
    gicpt_Int3,     // gicArmyFormation
    gicpt_Int4,     // gicArmyWalk
    gicpt_Int1,     // gicArmyStorm
    //II.      Unit commands
    gicpt_Int1,     // gicUnitDismiss
    gicpt_Int1,     // gicUnitDismissCancel
    //III.     Building/road plans (what to build and where)
    gicpt_Int3,     // gicBuildAddFieldPlan
    gicpt_Int2,     // gicBuildRemoveFieldPlan
    gicpt_Int2,     // gicBuildRemoveHouse
    gicpt_Int2,     // gicBuildRemoveHousePlan
    gicpt_Int3,     // gicBuildHousePlan
    //IV.    House repair/delivery/orders (TKMHouse, Toggle(repair, delivery, orders))
    gicpt_Int1,     // gicHouseRepairToggle
    gicpt_Int1,     // gicHouseDeliveryModeNext
    gicpt_Int1,     // gicHouseDeliveryModePrev
    gicpt_Int1,     // gicHouseClosedForWorkerTgl
    gicpt_Int3,     // gicHouseOrderProduct
    gicpt_Int2,     // gicHouseMarketFrom
    gicpt_Int2,     // gicHouseMarketTo
    gicpt_Int2,     // gicHouseWoodcutterMode
    gicpt_Int2,     // gicHouseArmorWSDeliveryToggle
    gicpt_Int2,     // gicHouseStoreNotAcceptFlag
    gicpt_Int2,     // gicHStoreNotAllowTakeOutFlag
    gicpt_Int3,     // gicHouseSchoolTrain
    gicpt_Int3,     // gicHouseSchoolTrainChOrder
    gicpt_Int2,     // gicHouseSchoolTrainChLastUOrder
    gicpt_Int2,     // gicHouseBarracksAcceptFlag
    gicpt_Int2,     // gicHBarracksNotAllowTakeOutFlag
    gicpt_Int1,     // gicHBarracksAcceptRecruitsTgl
    gicpt_Int3,     // gicHouseBarracksEquip
    gicpt_Int3,     // gicHouseBarracksRally
    gicpt_Int3,     // gicHouseTownHallEquip
    gicpt_Int3,     // gicHouseTownHallRally
    gicpt_Int2,     // gicHouseTownHallMaxGold
    gicpt_Int2,     // gicHouseRemoveTrain
    gicpt_Int3,     // gicHouseWoodcuttersCutting
    //V.     Delivery ratios changes (and other game-global settings)
    gicpt_Int3,     // gicWareDistributionChange
    gicpt_UniStr1,  // gicWareDistributions
    //VI.      Game changes
    gicpt_Int4,     // gicGameAlertBeacon
    gicpt_NoParams, // gicGamePause
    gicpt_Float,    // gicGameSpeed
    gicpt_Date,     // gicGameAutoSave
    gicpt_Date,     // gicGameAutoSaveAfterPT
    gicpt_Date,     // gicGameSaveReturnLobby
    gicpt_Int1,     // gicGameLoadSave
    gicpt_Int2,     // gicGameTeamChange
    gicpt_Int2,     // gicGameHotkeySet
    gicpt_Int1,     // gicGameMessageLogRead
    gicpt_Ansi1Int2,// gicGamePlayerChange
    gicpt_Int1,     // gicGamePlayerDefeat
    gicpt_Int3,     // gicGamePlayerAllianceSet
    gicpt_Int2,     // gicGameSetDefaultGoals
    //VII.     Scripting commands
    gicpt_Ansi1Uni4,// gicScriptConsoleCommand
    gicpt_Int1,     // gicScriptSoundRemoveRq
    //VIII.    Temporary and debug commands
    gicpt_Int2,     // gicTempAddScout
    gicpt_NoParams, // gicTempRevealMap
    gicpt_NoParams, // gicTempVictory
    gicpt_NoParams, // gicTempDefeat
    gicpt_NoParams  // gicTempDoNothing
  );

type
  TKMGameInputCommand = record
    CommandType: TKMGameInputCommandType;
    Params: array[1..MAX_PARAMS] of Integer;
    FloatParam: Single;
    AnsiStrParam: AnsiString;
    UnicodeStrParams: TKMScriptCommandParamsArray;
    DateTimeParam: TDateTime;
    HandIndex: TKMHandID; //Player for which the command is to be issued. (Needed for multiplayer and other reasons)
  end;

  function IsSelectedObjectCommand(aGIC: TKMGameInputCommandType): Boolean;
  //As TGameInputCommand is no longer fixed size (due to the string) we cannot simply read/write it as a block
  procedure SaveCommandToMemoryStream(const aCommand: TKMGameInputCommand; aMemoryStream: TKMemoryStream);
  procedure LoadCommandFromMemoryStream(out aCommand: TKMGameInputCommand; aMemoryStream: TKMemoryStream);

type

  TKMStoredGIPCommand = packed record
    Tick: Cardinal;
    Command: TKMGameInputCommand;
    Rand: Cardinal; //acts as CRC check
  end;

  TKMGameInputProcess = class
  private
    fCount: Integer;
    fReplayState: TKMGIPReplayState;
    fPlannedCommands: TList<TKMGameInputCommand>; //Commands that were made before game was started (f.e. gicPlayerTypeChange, gicGameSpeed), we plan them for the next tick
  protected
    fCursor: Integer; //Used only in gipReplaying
    fQueue: array of TKMStoredGIPCommand;
    fOnReplayDesync: TIntegerEvent;

    function MakeEmptyCommand(aGIC: TKMGameInputCommandType): TKMGameInputCommand; inline;
    function MakeCommand(aGIC: TKMGameInputCommandType): TKMGameInputCommand; overload;
    function MakeCommand(aGIC: TKMGameInputCommandType; const aParam1: Integer): TKMGameInputCommand; overload;
    function MakeCommand(aGIC: TKMGameInputCommandType; const aParam1, aParam2: Integer): TKMGameInputCommand; overload;
    function MakeCommand(aGIC: TKMGameInputCommandType; const aParam1, aParam2, aParam3: Integer): TKMGameInputCommand; overload;
    function MakeCommand(aGIC: TKMGameInputCommandType; const aParam1, aParam2, aParam3, aParam4: Integer): TKMGameInputCommand; overload;
    function MakeCommand(aGIC: TKMGameInputCommandType; const aAnsiTxtParam: AnsiString; const aParam1, aParam2: Integer): TKMGameInputCommand; overload;
    function MakeCommandNoHand(aGIC: TKMGameInputCommandType; const aParam1: Single): TKMGameInputCommand;
    function MakeCommand(aGIC: TKMGameInputCommandType; const aTextParam: UnicodeString): TKMGameInputCommand; overload;
    function MakeCommand(aGIC: TKMGameInputCommandType; const aAnsiTxtParam: AnsiString; const aUniTxtArray: TKMScriptCommandParamsArray): TKMGameInputCommand; overload;
    function MakeCommand(aGIC: TKMGameInputCommandType; aDateTimeParam: TDateTime): TKMGameInputCommand; overload;
    procedure TakeCommand(const aCommand: TKMGameInputCommand);
    procedure DoTakeCommand(const aCommand: TKMGameInputCommand); virtual; abstract;
    procedure ExecCommand(const aCommand: TKMGameInputCommand);
    procedure StoreCommand(const aCommand: TKMGameInputCommand);
    procedure ExecGameAlertBeaconCmd(const aCommand: TKMGameInputCommand);

    function DoSkipLogCommand(const aCommand: TKMGameInputCommand): Boolean;
    function QueueToString: String;

    function IsLastTickValueCorrect(aLastTickValue: Cardinal): Boolean;
    procedure SaveExtra(SaveStream: TKMemoryStream); virtual;
    procedure LoadExtra(LoadStream: TKMemoryStream); virtual;

    function GetNetPlayerName(aHandIndex: TKMHandID): String; virtual;
    function IsPlayerMuted(aHandIndex: Integer): Boolean; virtual;
  public
    constructor Create(aReplayState: TKMGIPReplayState);
    destructor Destroy; override;

    procedure CmdArmy(aCommandType: TKMGameInputCommandType; aGroup: TKMUnitGroup); overload;
    procedure CmdArmy(aCommandType: TKMGameInputCommandType; aGroup: TKMUnitGroup; aUnit: TKMUnit); overload;
    procedure CmdArmy(aCommandType: TKMGameInputCommandType; aGroup1, aGroup2: TKMUnitGroup); overload;
    procedure CmdArmy(aCommandType: TKMGameInputCommandType; aGroup: TKMUnitGroup; aHouse: TKMHouse); overload;
    procedure CmdArmy(aCommandType: TKMGameInputCommandType; aGroup: TKMUnitGroup; aTurnAmount: TKMTurnDirection; aLineAmount:shortint); overload;
    procedure CmdArmy(aCommandType: TKMGameInputCommandType; aGroup: TKMUnitGroup; const aLoc: TKMPoint; aDirection: TKMDirection); overload;

    procedure CmdUnit(aCommandType: TKMGameInputCommandType; aUnit: TKMUnit);

    procedure CmdBuild(aCommandType: TKMGameInputCommandType; const aLoc: TKMPoint); overload;
    procedure CmdBuild(aCommandType: TKMGameInputCommandType; const aLoc: TKMPoint; aFieldType: TKMFieldType); overload;
    procedure CmdBuild(aCommandType: TKMGameInputCommandType; const aLoc: TKMPoint; aHouseType: TKMHouseType); overload;

    procedure CmdHouse(aCommandType: TKMGameInputCommandType; aHouse: TKMHouse); overload;
    procedure CmdHouse(aCommandType: TKMGameInputCommandType; aHouse: TKMHouse; aItem, aAmountChange: Integer); overload;
    procedure CmdHouse(aCommandType: TKMGameInputCommandType; aHouse: TKMHouse; aWareType: TKMWareType); overload;
    procedure CmdHouse(aCommandType: TKMGameInputCommandType; aHouse: TKMHouse; aWoodcutterMode: TKMWoodcutterMode); overload;
    procedure CmdHouse(aCommandType: TKMGameInputCommandType; aHouse: TKMHouse; aUnitType: TKMUnitType; aCount: Integer); overload;
    procedure CmdHouse(aCommandType: TKMGameInputCommandType; aHouse: TKMHouse; aValue: Integer); overload;
    procedure CmdHouse(aCommandType: TKMGameInputCommandType; aHouse: TKMHouse; const aLoc: TKMPoint); overload;

    procedure CmdWareDistribution(aCommandType: TKMGameInputCommandType; aWare: TKMWareType; aHouseType: TKMHouseType; aValue:integer); overload;
    procedure CmdWareDistribution(aCommandType: TKMGameInputCommandType; const aTextParam: UnicodeString); overload;

    procedure CmdConsoleCommand(aCommandType: TKMGameInputCommandType; const aAnsiTxtParam: AnsiString;
                                const aUniTxtArray: TKMScriptCommandParamsArray);

    procedure CmdGame(aCommandType: TKMGameInputCommandType; aDateTime: TDateTime); overload;
    procedure CmdGame(aCommandType: TKMGameInputCommandType; aParam1, aParam2: Integer); overload;
    procedure CmdGame(aCommandType: TKMGameInputCommandType; const aLoc: TKMPointF; aOwner: TKMHandID; aColor: Cardinal); overload;
    procedure CmdGame(aCommandType: TKMGameInputCommandType; aValue: Integer); overload;
    procedure CmdGame(aCommandType: TKMGameInputCommandType; aValue: Single); overload;

    procedure CmdPlayerAllianceSet(aForPlayer, aToPlayer: TKMHandID; aAllianceType: TKMAllianceType);
    procedure CmdPlayerAddDefaultGoals(aPlayer: TKMHandID; aBuilding: Boolean);
    procedure CmdPlayerChanged(aPlayer: TKMHandID; aType: TKMHandType; aPlayerNikname: AnsiString);

    procedure CmdScriptSoundRemoveRequest(aScriptSoundUID: Integer);

    procedure CmdTemp(aCommandType: TKMGameInputCommandType; const aLoc: TKMPoint); overload;
    procedure CmdTemp(aCommandType: TKMGameInputCommandType); overload;

    procedure ReplayTimer(aTick: Cardinal); virtual;
    procedure RunningTimer(aTick: Cardinal); virtual;
    procedure TakePlannedCommands;
    procedure UpdateState(aTick: Cardinal); virtual;

    //Replay methods
    procedure SaveToStream(SaveStream: TKMemoryStream);
    procedure SaveToFile(const aFileName: UnicodeString);
    procedure SaveToFileAsync(const aFileName: UnicodeString; aWorkerThread: TKMWorkerThread);
    procedure LoadFromStream(LoadStream: TKMemoryStream);
    procedure LoadFromFile(const aFileName: UnicodeString);
    property Count: Integer read fCount;
    property ReplayState: TKMGIPReplayState read fReplayState;
    function GetLastTick: Cardinal;
    function ReplayEnded: Boolean;
    procedure MoveCursorTo(aTick: Integer);

    property OnReplayDesync: TIntegerEvent read fOnReplayDesync write fOnReplayDesync;

    function GIPCommandToString(aGIC: TKMGameInputCommand): UnicodeString;
    function StoredGIPCommandToString(aCommand: TKMStoredGIPCommand): String;

    procedure Paint;
  end;


implementation
uses
  SysUtils, TypInfo, Math,
  KM_GameApp, KM_Game, KM_GameParams, KM_HandsCollection,
  KM_HouseMarket, KM_HouseBarracks, KM_HouseSchool, KM_HouseTownHall,
  KM_ScriptingEvents, KM_Alerts, KM_CommonUtils, KM_Log, KM_RenderUI,
  KM_GameTypes, KM_ResFonts, KM_Settings, KM_Resource;

const 
  NO_LAST_TICK_VALUE = 0;

var
  GIC_COMMAND_TYPE_MAX_LENGTH: Byte;


function IsSelectedObjectCommand(aGIC: TKMGameInputCommandType): Boolean;
begin
  Result := (aGIC in ARMY_ORDER_COMMANDS) or (aGIC in HOUSE_ORDER_COMMANDS);
end;


procedure SaveCommandToMemoryStream(const aCommand: TKMGameInputCommand; aMemoryStream: TKMemoryStream);
begin
  with aCommand do
  begin
    aMemoryStream.Write(CommandType, SizeOf(CommandType));
    case COMMAND_PACK_TYPES[CommandType] of
      gicpt_NoParams: ;
      gicpt_Int1:     aMemoryStream.Write(Params[1]);
      gicpt_Int2:     begin
                        aMemoryStream.Write(Params[1]);
                        aMemoryStream.Write(Params[2]);
                      end;
      gicpt_Int3:     begin
                        aMemoryStream.Write(Params[1]);
                        aMemoryStream.Write(Params[2]);
                        aMemoryStream.Write(Params[3]);
                      end;
      gicpt_Int4:     begin
                        aMemoryStream.Write(Params[1]);
                        aMemoryStream.Write(Params[2]);
                        aMemoryStream.Write(Params[3]);
                        aMemoryStream.Write(Params[4]);
                      end;
      gicpt_Ansi1Int2:begin
                        aMemoryStream.WriteA(AnsiStrParam);
                        aMemoryStream.Write(Params[1]);
                        aMemoryStream.Write(Params[2]);
                      end;
      gicpt_Float:    aMemoryStream.Write(FloatParam);
      gicpt_UniStr1:  aMemoryStream.WriteW(UnicodeStrParams[0]);
      gicpt_Ansi1Uni4:begin
                        aMemoryStream.WriteA(AnsiStrParam);
                        aMemoryStream.WriteW(UnicodeStrParams[0]);
                        aMemoryStream.WriteW(UnicodeStrParams[1]);
                        aMemoryStream.WriteW(UnicodeStrParams[2]);
                        aMemoryStream.WriteW(UnicodeStrParams[3]);
                      end;
      gicpt_Date:     aMemoryStream.Write(DateTimeParam);
    end;
    aMemoryStream.Write(HandIndex);
  end;
end;


procedure LoadCommandFromMemoryStream(out aCommand: TKMGameInputCommand; aMemoryStream: TKMemoryStream);
begin
  with aCommand do
  begin
    aMemoryStream.Read(CommandType, SizeOf(CommandType));
    case COMMAND_PACK_TYPES[CommandType] of
      gicpt_NoParams: ;
      gicpt_Int1:     aMemoryStream.Read(Params[1]);
      gicpt_Int2:     begin
                        aMemoryStream.Read(Params[1]);
                        aMemoryStream.Read(Params[2]);
                      end;
      gicpt_Int3:     begin
                        aMemoryStream.Read(Params[1]);
                        aMemoryStream.Read(Params[2]);
                        aMemoryStream.Read(Params[3]);
                      end;
      gicpt_Int4:     begin
                        aMemoryStream.Read(Params[1]);
                        aMemoryStream.Read(Params[2]);
                        aMemoryStream.Read(Params[3]);
                        aMemoryStream.Read(Params[4]);
                      end;
      gicpt_Ansi1Int2:begin
                        aMemoryStream.ReadA(AnsiStrParam);
                        aMemoryStream.Read(Params[1]);
                        aMemoryStream.Read(Params[2]);
                      end;
      gicpt_Float:    aMemoryStream.Read(FloatParam);
      gicpt_UniStr1:  aMemoryStream.ReadW(UnicodeStrParams[0]);
      gicpt_Ansi1Uni4:begin
                        aMemoryStream.ReadA(AnsiStrParam);
                        aMemoryStream.ReadW(UnicodeStrParams[0]);
                        aMemoryStream.ReadW(UnicodeStrParams[1]);
                        aMemoryStream.ReadW(UnicodeStrParams[2]);
                        aMemoryStream.ReadW(UnicodeStrParams[3]);
                      end;
      gicpt_Date:     aMemoryStream.Read(DateTimeParam);
    end;
    aMemoryStream.Read(HandIndex);
  end;
end;


function TKMGameInputProcess.GetNetPlayerName(aHandIndex: TKMHandID): String;
begin
  Result := '';
end;


function TKMGameInputProcess.GIPCommandToString(aGIC: TKMGameInputCommand): UnicodeString;
begin
  with aGIC do
  begin
    Result := Format('%-' + IntToStr(GIC_COMMAND_TYPE_MAX_LENGTH) + 's hand: %2d' + GetNetPlayerName(HandIndex) + ', params: ',
                     [GetEnumName(TypeInfo(TKMGameInputCommandType), Integer(CommandType)), HandIndex]);
    case COMMAND_PACK_TYPES[CommandType] of
      gicpt_NoParams:   Result := Result + ' []';
      gicpt_Int1:       Result := Result + Format('[%10d]', [Params[1]]);
      gicpt_Int2:       Result := Result + Format('[%10d,%10d]', [Params[1], Params[2]]);
      gicpt_Int3:       Result := Result + Format('[%10d,%10d,%10d]', [Params[1], Params[2], Params[3]]);
      gicpt_Int4:       Result := Result + Format('[%10d,%10d,%10d,%10d]', [Params[1], Params[2], Params[3], Params[4]]);
      gicpt_Ansi1Int2:  Result := Result + Format('[S1=%s,%10d,%10d]', [AnsiStrParam, Params[1], Params[2]]);
      gicpt_UniStr1:    Result := Result + Format('[%s]', [UnicodeStrParams[0]]);
      gicpt_Float:      Result := Result + Format('[%f]', [FloatParam]);
      gicpt_Ansi1Uni4:  Result := Result + Format('[S1=%s,S2=%s,S3=%s,S4=%s,S5=%s]', [AnsiStrParam, UnicodeStrParams[0], UnicodeStrParams[1],UnicodeStrParams[2],UnicodeStrParams[3]]);
      gicpt_Date:       Result := Result + Format('[%s]', [FormatDateTime('dd.mm.yy hh:nn:ss.zzz', DateTimeParam)]);
      else              ;
    end;
  end;
end;


{ TGameInputProcess }
constructor TKMGameInputProcess.Create(aReplayState: TKMGIPReplayState);
begin
  inherited Create;

  SetLength(fQueue, 128);
  fCount := 0;
  fCursor := 1;
  fReplayState := aReplayState;

  fPlannedCommands := TList<TKMGameInputCommand>.Create;
end;


destructor TKMGameInputProcess.Destroy;
begin
  fPlannedCommands.Free;

  inherited;
end;


function TKMGameInputProcess.MakeEmptyCommand(aGIC: TKMGameInputCommandType): TKMGameInputCommand;
begin
  Result.CommandType := aGIC;
  Result.HandIndex := gMySpectator.HandID;
end;


procedure TKMGameInputProcess.MoveCursorTo(aTick: Integer);
begin
  fCursor := aTick;
end;


function TKMGameInputProcess.MakeCommand(aGIC: TKMGameInputCommandType): TKMGameInputCommand;
begin
  Assert(COMMAND_PACK_TYPES[aGIC] = gicpt_NoParams,
         Format('Wrong packing type for command %s: Expected: gicpt_NoParams Actual: [%s]',
                [GetEnumName(TypeInfo(TKMGameInputCommandType), Integer(aGIC)),
                 GetEnumName(TypeInfo(TKMGameInputCommandPackType), Integer(COMMAND_PACK_TYPES[aGIC]))]));
  Result := MakeEmptyCommand(aGIC);
end;


function TKMGameInputProcess.MakeCommand(aGIC: TKMGameInputCommandType; const aParam1: Integer): TKMGameInputCommand;
begin
  Assert(COMMAND_PACK_TYPES[aGIC] = gicpt_Int1,
         Format('Wrong packing type for command %s: Expected: gicpt_Int1 Actual: [%s]',
                [GetEnumName(TypeInfo(TKMGameInputCommandType), Integer(aGIC)),
                 GetEnumName(TypeInfo(TKMGameInputCommandPackType), Integer(COMMAND_PACK_TYPES[aGIC]))]));
  Result := MakeEmptyCommand(aGIC);
  Result.Params[1] := aParam1;
end;


function TKMGameInputProcess.MakeCommand(aGIC: TKMGameInputCommandType; const aParam1, aParam2: Integer): TKMGameInputCommand;
begin
  Assert(COMMAND_PACK_TYPES[aGIC] = gicpt_Int2,
         Format('Wrong packing type for command %s: Expected: gicpt_Int2 Actual: [%s]',
                [GetEnumName(TypeInfo(TKMGameInputCommandType), Integer(aGIC)),
                 GetEnumName(TypeInfo(TKMGameInputCommandPackType), Integer(COMMAND_PACK_TYPES[aGIC]))]));
  Result := MakeEmptyCommand(aGIC);
  Result.Params[1] := aParam1;
  Result.Params[2] := aParam2;
end;


function TKMGameInputProcess.MakeCommand(aGIC: TKMGameInputCommandType; const aParam1, aParam2, aParam3: Integer): TKMGameInputCommand;
begin
  Assert(COMMAND_PACK_TYPES[aGIC] = gicpt_Int3,
         Format('Wrong packing type for command %s: Expected: gicpt_Int3 Actual: [%s]',
                [GetEnumName(TypeInfo(TKMGameInputCommandType), Integer(aGIC)),
                 GetEnumName(TypeInfo(TKMGameInputCommandPackType), Integer(COMMAND_PACK_TYPES[aGIC]))]));
  Result := MakeEmptyCommand(aGIC);
  Result.Params[1] := aParam1;
  Result.Params[2] := aParam2;
  Result.Params[3] := aParam3;
end;


function TKMGameInputProcess.MakeCommand(aGIC: TKMGameInputCommandType; const aParam1, aParam2, aParam3, aParam4: Integer): TKMGameInputCommand;
begin
  Assert(COMMAND_PACK_TYPES[aGIC] = gicpt_Int4,
         Format('Wrong packing type for command %s: Expected: gicpt_Int4 Actual: [%s]',
                [GetEnumName(TypeInfo(TKMGameInputCommandType), Integer(aGIC)),
                 GetEnumName(TypeInfo(TKMGameInputCommandPackType), Integer(COMMAND_PACK_TYPES[aGIC]))]));
  Result := MakeEmptyCommand(aGIC);
  Result.Params[1] := aParam1;
  Result.Params[2] := aParam2;
  Result.Params[3] := aParam3;
  Result.Params[4] := aParam4;
end;


function TKMGameInputProcess.MakeCommand(aGIC: TKMGameInputCommandType; const aAnsiTxtParam: AnsiString; const aParam1, aParam2: Integer): TKMGameInputCommand;
begin
  Assert(COMMAND_PACK_TYPES[aGIC] = gicpt_Ansi1Int2,
         Format('Wrong packing type for command %s: Expected: gicpt_Ansi1Int2 Actual: [%s]',
                [GetEnumName(TypeInfo(TKMGameInputCommandType), Integer(aGIC)),
                 GetEnumName(TypeInfo(TKMGameInputCommandPackType), Integer(COMMAND_PACK_TYPES[aGIC]))]));
  Result := MakeEmptyCommand(aGIC);
  Result.AnsiStrParam := aAnsiTxtParam;
  Result.Params[1] := aParam1;
  Result.Params[2] := aParam2;
end;


function TKMGameInputProcess.MakeCommandNoHand(aGIC: TKMGameInputCommandType; const aParam1: Single): TKMGameInputCommand;
begin
  Assert(COMMAND_PACK_TYPES[aGIC] = gicpt_Float,
         Format('Wrong packing type for command %s: Expected: gicpt_Float Actual: [%s]',
                [GetEnumName(TypeInfo(TKMGameInputCommandType), Integer(aGIC)),
                 GetEnumName(TypeInfo(TKMGameInputCommandPackType), Integer(COMMAND_PACK_TYPES[aGIC]))]));
  Result.HandIndex := -1;
  Result.CommandType := aGIC;
  Result.FloatParam := aParam1;
end;


function TKMGameInputProcess.MakeCommand(aGIC: TKMGameInputCommandType; const aTextParam: UnicodeString): TKMGameInputCommand;
begin
  Assert(COMMAND_PACK_TYPES[aGIC] = gicpt_UniStr1,
         Format('Wrong packing type for command %s: Expected: gicpt_Text Actual: [%s]',
                [GetEnumName(TypeInfo(TKMGameInputCommandType), Integer(aGIC)),
                 GetEnumName(TypeInfo(TKMGameInputCommandPackType), Integer(COMMAND_PACK_TYPES[aGIC]))]));
  Result := MakeEmptyCommand(aGIC);

  Result.UnicodeStrParams[0] := aTextParam;
end;


function TKMGameInputProcess.MakeCommand(aGIC: TKMGameInputCommandType; const aAnsiTxtParam: AnsiString;
                                         const aUniTxtArray: TKMScriptCommandParamsArray): TKMGameInputCommand;
var
  I: Integer;
begin
  Assert(COMMAND_PACK_TYPES[aGIC] = gicpt_Ansi1Uni4,
         Format('Wrong packing type for command %s: Expected: gicpt_Ansi1Uni4 Actual: [%s]',
                [GetEnumName(TypeInfo(TKMGameInputCommandType), Integer(aGIC)),
                 GetEnumName(TypeInfo(TKMGameInputCommandPackType), Integer(COMMAND_PACK_TYPES[aGIC]))]));
  Result := MakeEmptyCommand(aGIC);

  Result.AnsiStrParam := aAnsiTxtParam;

  for I := 0 to Length(aUniTxtArray) - 1 do
    Result.UnicodeStrParams[I] := aUniTxtArray[I];
end;


function TKMGameInputProcess.MakeCommand(aGIC: TKMGameInputCommandType; aDateTimeParam: TDateTime): TKMGameInputCommand;
begin
  Assert(COMMAND_PACK_TYPES[aGIC] = gicpt_Date,
         Format('Wrong packing type for command %s: Expected: gicpt_Date Actual: [%s]',
                [GetEnumName(TypeInfo(TKMGameInputCommandType), Integer(aGIC)),
                 GetEnumName(TypeInfo(TKMGameInputCommandPackType), Integer(COMMAND_PACK_TYPES[aGIC]))]));
  Result := MakeEmptyCommand(aGIC);

  Result.DateTimeParam := aDateTimeParam;
end;


function TKMGameInputProcess.DoSkipLogCommand(const aCommand: TKMGameInputCommand): Boolean;
begin
  Result := SKIP_LOG_TEMP_COMMANDS and (aCommand.CommandType in [gicTempAddScout, gicTempRevealMap, gicTempVictory, gicTempDefeat, gicTempDoNothing]);
end;


procedure TKMGameInputProcess.TakeCommand(const aCommand: TKMGameInputCommand);
begin
  if gGame.IsStarted
    and (gGameParams.Tick > 0) then //We could get some commands even before 1st game update (on tick 0)
    DoTakeCommand(aCommand)
  else
    fPlannedCommands.Add(aCommand);
end;


procedure TKMGameInputProcess.ExecCommand(const aCommand: TKMGameInputCommand);
var
  P: TKMHand;
  isSilent: Boolean;
  srcUnit: TKMUnit;
  srcGroup, TgtGroup: TKMUnitGroup;
  tgtUnit: TKMUnit;
  srcHouse, tgtHouse: TKMHouse;
begin
  //NOTE: gMySpectator.PlayerIndex should not be used for important stuff here, use P instead (commands must be executed the same for all players)
  isSilent := (aCommand.HandIndex <> gMySpectator.HandID);
  P := gHands[aCommand.HandIndex];
  srcUnit := nil;
  srcGroup := nil;
  TgtGroup := nil;
  srcHouse := nil;
  tgtHouse := nil;
  tgtUnit := nil;

  with aCommand do
  begin
    //It is possible that units/houses have died by now
    if CommandType in [gicArmyFeed, gicArmySplit, gicArmySplitSingle, gicArmyLink,
                       gicArmyAttackUnit, gicArmyAttackHouse, gicArmyHalt,
                       gicArmyFormation, gicArmyWalk, gicArmyStorm]
    then
    begin
      srcGroup := gHands.GetGroupByUID(Params[1]);
      if (srcGroup = nil) or srcGroup.IsDead //Group has died before command could be executed
      or (srcGroup.Owner <> aCommand.HandIndex) then //Potential exploit
        Exit;
    end;
    if CommandType in [gicArmyLink] then
    begin
      TgtGroup := gHands.GetGroupByUID(Params[2]);
      if (TgtGroup = nil) or TgtGroup.IsDead //Unit has died before command could be executed
      or (TgtGroup.Owner <> aCommand.HandIndex) then //Potential exploit
        Exit;
    end;
    if CommandType in [gicArmyAttackUnit] then
    begin
      tgtUnit := gHands.GetUnitByUID(Params[2]);
      if (tgtUnit = nil) or tgtUnit.IsDeadOrDying then //Unit has died before command could be executed
        Exit;
    end;
    if CommandType in [gicHouseRepairToggle, gicHouseDeliveryModeNext, gicHouseDeliveryModePrev, gicHouseWoodcuttersCutting, gicHouseTownHallMaxGold,
      gicHouseOrderProduct, gicHouseMarketFrom, gicHouseMarketTo, gicHouseBarracksRally, gicHouseTownHallRally,
      gicHouseStoreNotAcceptFlag, gicHStoreNotAllowTakeOutFlag, gicHouseBarracksAcceptFlag, gicHBarracksNotAllowTakeOutFlag,
      gicHouseBarracksEquip, gicHouseTownHallEquip, gicHouseClosedForWorkerTgl,
      gicHouseSchoolTrain, gicHouseSchoolTrainChOrder, gicHouseSchoolTrainChLastUOrder, gicHouseRemoveTrain,
      gicHouseWoodcutterMode, gicHBarracksAcceptRecruitsTgl, gicHouseArmorWSDeliveryToggle] then
    begin
      srcHouse := gHands.GetHouseByUID(Params[1]);
      if (srcHouse = nil) or srcHouse.IsDestroyed //House has been destroyed before command could be executed
      or (srcHouse.Owner <> aCommand.HandIndex) then //Potential exploit
        Exit;
    end;
    if CommandType in [gicArmyAttackHouse] then
    begin
      tgtHouse := gHands.GetHouseByUID(Params[2]);
      if (tgtHouse = nil) or tgtHouse.IsDestroyed then Exit; //House has been destroyed before command could be executed
    end;

    if CommandType in [gicUnitDismiss, gicUnitDismissCancel] then
    begin
      srcUnit := gHands.GetUnitByUID(Params[1]);
      if (srcUnit = nil) or srcUnit.IsDeadOrDying //Unit has died before command could be executed
        or (srcUnit.Owner <> aCommand.HandIndex) then //Potential exploit
        Exit;
    end;

    //Some commands are blocked by peacetime (this is a fall back in case players try to cheat)
    if gGame.IsPeaceTime and (CommandType in BLOCKED_BY_PEACETIME) then
       Exit;

    //No commands allowed after a player has lost (this is a fall back in case players try to cheat)
    if not (aCommand.CommandType in ALLOWED_AFTER_DEFEAT) and P.AI.HasLost then
      Exit;

    //Most commands blocked during cinematic (this is a fall back in case players try to cheat)
    if not (aCommand.CommandType in ALLOWED_IN_CINEMATIC) and (P.InCinematic) then
      Exit;

    if gLog.CanLogCommands() and not DoSkipLogCommand(aCommand) then
      gLog.LogCommands(Format('Tick: %6d Exec command: %s', [gGameParams.Tick, GIPCommandToString(aCommand)]));

    case CommandType of
      gicArmyFeed:         srcGroup.OrderFood(True);
      gicArmySplit:        srcGroup.OrderSplit;
      gicArmySplitSingle:  srcGroup.OrderSplit(True);
      gicArmyStorm:        srcGroup.OrderStorm(True);
      gicArmyLink:         srcGroup.OrderLinkTo(TgtGroup, True);
      gicArmyAttackUnit:   srcGroup.OrderAttackUnit(tgtUnit, True);
      gicArmyAttackHouse:  srcGroup.OrderAttackHouse(tgtHouse, True);
      gicArmyHalt:         srcGroup.OrderHalt(True);
      gicArmyFormation:    srcGroup.OrderFormation(TKMTurnDirection(Params[2]),Params[3], True);
      gicArmyWalk:         srcGroup.OrderWalk(KMPoint(Params[2],Params[3]), True, wtokPlayerOrder, TKMDirection(Params[4]));

      gicUnitDismiss:        srcUnit.Dismiss;
      gicUnitDismissCancel:  srcUnit.DismissCancel;

      gicBuildToggleFieldPlan:   P.ToggleFieldPlan(KMPoint(Params[1],Params[2]), TKMFieldType(Params[3]), not gGameParams.IsMultiPlayerOrSpec); //Make sound in singleplayer mode only
      gicBuildRemoveFieldPlan:   P.RemFieldPlan(KMPoint(Params[1],Params[2]), not gGameParams.IsMultiPlayerOrSpec); //Make sound in singleplayer mode only
      gicBuildRemoveHouse:       P.RemHouse(KMPoint(Params[1],Params[2]), isSilent);
      gicBuildRemoveHousePlan:   P.RemHousePlan(KMPoint(Params[1],Params[2]));
      gicBuildHousePlan:         if P.CanAddHousePlan(KMPoint(Params[2],Params[3]), TKMHouseType(Params[1])) then
                                    P.AddHousePlan(TKMHouseType(Params[1]), KMPoint(Params[2],Params[3]));

      gicHouseRepairToggle:      srcHouse.BuildingRepair := not srcHouse.BuildingRepair;
      gicHouseDeliveryModeNext:   //Delivery mode has to be delayed, to avoid occasional delivery mode button clicks
                                  srcHouse.SetNextDeliveryMode;
      gicHouseDeliveryModePrev:   //Delivery mode has to be delayed, to avoid occasional delivery mode button clicks
                                  srcHouse.SetPrevDeliveryMode;
      gicHouseClosedForWorkerTgl: srcHouse.IsClosedForWorker := not srcHouse.IsClosedForWorker;
      gicHouseOrderProduct:      srcHouse.ResOrder[Params[2]] := srcHouse.ResOrder[Params[2]] + Params[3];
      gicHouseMarketFrom:        TKMHouseMarket(srcHouse).ResFrom := TKMWareType(Params[2]);
      gicHouseMarketTo:          TKMHouseMarket(srcHouse).ResTo := TKMWareType(Params[2]);
      gicHouseStoreNotAcceptFlag:   TKMHouseStore(srcHouse).ToggleNotAcceptFlag(TKMWareType(Params[2]));
      gicHStoreNotAllowTakeOutFlag:
                                 TKMHouseStore(srcHouse).ToggleNotAcceptTakeOutFlag(TKMWareType(Params[2]));
      gicHouseWoodcutterMode:    TKMHouseWoodcutters(srcHouse).WoodcutterMode := TKMWoodcutterMode(Params[2]);
      gicHouseBarracksAcceptFlag:
                                  TKMHouseBarracks(srcHouse).ToggleNotAcceptFlag(TKMWareType(Params[2]));
      gicHBarracksNotAllowTakeOutFlag:
                                  TKMHouseBarracks(srcHouse).ToggleNotAllowTakeOutFlag(TKMWareType(Params[2]));
      gicHBarracksAcceptRecruitsTgl:
                                  TKMHouseBarracks(srcHouse).ToggleAcceptRecruits;
      gicHouseBarracksEquip:     TKMHouseBarracks(srcHouse).Equip(TKMUnitType(Params[2]), Params[3]);
      gicHouseBarracksRally:     TKMHouseBarracks(srcHouse).FlagPoint := KMPoint(Params[2], Params[3]);
      gicHouseTownHallEquip:     TKMHouseTownHall(srcHouse).Equip(TKMUnitType(Params[2]), Params[3]);
      gicHouseTownHallRally:     TKMHouseTownHall(srcHouse).FlagPoint := KMPoint(Params[2], Params[3]);
      gicHouseTownHallMaxGold:   TKMHouseTownHall(srcHouse).GoldMaxCnt := EnsureRange(Params[2], 0, High(Word));
      gicHouseSchoolTrain:       TKMHouseSchool(srcHouse).AddUnitToQueue(TKMUnitType(Params[2]), Params[3]);
      gicHouseSchoolTrainChOrder:TKMHouseSchool(srcHouse).ChangeUnitTrainOrder(Params[2], Params[3]);
      gicHouseSchoolTrainChLastUOrder: TKMHouseSchool(srcHouse).ChangeUnitTrainOrder(Params[2]);
      gicHouseRemoveTrain:       TKMHouseSchool(srcHouse).RemUnitFromQueue(Params[2]);
      gicHouseWoodcuttersCutting: TKMHouseWoodcutters(srcHouse).FlagPoint := KMPoint(Params[2], Params[3]);
      gicHouseArmorWSDeliveryToggle:   TKMHouseArmorWorkshop(srcHouse).ToggleResDelivery(TKMWareType(Params[2]));

      gicWareDistributionChange:  begin
                                    P.Stats.WareDistribution[TKMWareType(Params[1]), TKMHouseType(Params[2])] := Params[3];
                                    P.Houses.UpdateResRequest;
                                  end;
      gicWareDistributions:       begin
                                    P.Stats.WareDistribution.LoadFromStr(UnicodeStrParams[0]);
                                    P.Houses.UpdateResRequest;
                                  end;

      gicTempAddScout:            if DEBUG_CHEATS and (MULTIPLAYER_CHEATS or not gGameParams.IsMultiPlayerOrSpec) then
                                    //Place a warrior
                                    P.AddUnit(utHorseScout, KMPoint(Params[1], Params[2]), True, 0, True);
      gicTempRevealMap:           if DEBUG_CHEATS and (MULTIPLAYER_CHEATS or not gGameParams.IsMultiPlayerOrSpec) then
                                    P.FogOfWar.RevealEverything;
      gicTempVictory:             if DEBUG_CHEATS and (MULTIPLAYER_CHEATS or not gGameParams.IsMultiPlayerOrSpec) then
                                    P.AI.Victory;
      gicTempDefeat:              if DEBUG_CHEATS and (MULTIPLAYER_CHEATS or not gGameParams.IsMultiPlayerOrSpec) then
                                    P.AI.Defeat;
      gicTempDoNothing:           ;

      gicGamePause:               ;//if fReplayState = gipRecording then fGame.fGamePlayInterface.SetPause(boolean(Params[1]));
      gicGameSpeed:               gGame.SetSpeedGIP(FloatParam, fReplayState = gipRecording);
      gicGameAutoSave:            if (fReplayState = gipRecording) and gGameSettings.Autosave then
                                    gGame.AutoSave(DateTimeParam); //Timestamp is synchronised
      gicGameAutoSaveAfterPT:     if (fReplayState = gipRecording) and gGameSettings.Autosave then
                                    gGame.AutoSaveAfterPT(DateTimeParam); //Timestamp is synchronised
      gicGameSaveReturnLobby:     if fReplayState = gipRecording then
                                  begin
                                    gGameApp.PrepareReturnToLobby(DateTimeParam); //Timestamp is synchronised
                                    Exit;
                                  end;
      gicGameLoadSave:            ; //Just a marker to know when game was loaded
      gicGameTeamChange:          begin
                                    //Currently unused, disabled to prevent potential exploitation
                                    {fGame.Networking.NetPlayers[Params[1]].Team := Params[2];
                                    fGame.UpdateMultiplayerTeams;
                                    fPlayers.SyncFogOfWar;
                                    if fGame.Networking.IsHost then
                                      fGame.Networking.SendPlayerListAndRefreshPlayersSetup;}
                                  end;
      gicGameAlertBeacon:         ExecGameAlertBeaconCmd(aCommand);
      gicGameHotkeySet:           P.SelectionHotkeys[Params[1]] := Params[2];
      gicGameMessageLogRead:      P.MessageLog[Params[1]].IsReadGIP := True;
      gicGamePlayerChange:        begin
                                    Assert(not gGameParams.IsMapEditor);
                                    gHands[Params[1]].HandType := TKMHandType(Params[2]);
                                    gHands[Params[1]].OwnerNikname := AnsiStrParam;
                                    gGame.GamePlayInterface.UpdateUI; //Update players drop list
                                  end;
      gicGamePlayerDefeat:        begin
                                    gHands.UpdateGoalsForHand(Params[1], False);
                                    gHands[Params[1]].AI.Defeat(False);
                                  end;
      gicGamePlayerAllianceSet:   gHands[Params[1]].Alliances[Params[2]] := TKMAllianceType(Params[3]);
      gicGamePlayerAddDefGoals:     gHands[Params[1]].AI.AddDefaultGoals(IntToBool(Params[2]));
      gicScriptConsoleCommand:    gScriptEvents.CallConsoleCommand(HandIndex, AnsiStrParam, UnicodeStrParams);
      gicScriptSoundRemoveRq:     gGame.AddScriptSoundRemoveRequest(Params[1], HandIndex);
      else                        raise Exception.Create('Unexpected gic command');
    end;
  end;
end;


function TKMGameInputProcess.IsPlayerMuted(aHandIndex: Integer): Boolean;
begin
  Result := False;
end;


procedure TKMGameInputProcess.ExecGameAlertBeaconCmd(const aCommand: TKMGameInputCommand);

  function DoAddPlayerBeacon: Boolean;
  var
    handId: Integer;
  begin
    handId := aCommand.Params[3];

    Result := (gHands.CheckAlliance(handId, gMySpectator.HandID) = atAlly)
      and (gHands[handId].ShareBeacons[gMySpectator.HandID])
      and not IsPlayerMuted(handId); // do not show beacons sended by muted players
  end;

var
  doAddBeacon: Boolean;
begin
  // Beacon script event must always be run by all players for consistency
  gScriptEvents.ProcBeacon(aCommand.Params[3], 1 + (aCommand.Params[1] div 10), 1 + (aCommand.Params[2] div 10));

  doAddBeacon := False;

  case gGameParams.Mode of
    gmSingle,
    gmCampaign,
    gmMulti:          doAddBeacon := (aCommand.Params[3] <> PLAYER_NONE) and DoAddPlayerBeacon;
    gmMultiSpectate:  doAddBeacon := (aCommand.Params[3] = PLAYER_NONE) // Show spectators beacons while spectating
                                    or (gGameSettings.SpecShowBeacons and DoAddPlayerBeacon);
    gmReplaySingle,
    gmReplayMulti:    doAddBeacon := (aCommand.Params[3] <> PLAYER_NONE)  // Do not show spectators beacons in replay
                                    and gGameSettings.ReplayShowBeacons and DoAddPlayerBeacon;
  end;

  if doAddBeacon then
    gGame.GamePlayInterface.Alerts.AddBeacon(KMPointF(aCommand.Params[1]/10,
                                                      aCommand.Params[2]/10),
                                                      aCommand.Params[3],
                                                      (aCommand.Params[4] or $FF000000),
                                                      gGameApp.GlobalTickCount + ALERT_DURATION[atBeacon]);
end;


procedure TKMGameInputProcess.CmdArmy(aCommandType: TKMGameInputCommandType; aGroup: TKMUnitGroup);
begin
  Assert(aCommandType in [gicArmyFeed, gicArmySplit, gicArmySplitSingle, gicArmyStorm, gicArmyHalt]);
  TakeCommand(MakeCommand(aCommandType, aGroup.UID));
end;


procedure TKMGameInputProcess.CmdArmy(aCommandType: TKMGameInputCommandType; aGroup: TKMUnitGroup; aUnit: TKMUnit);
begin
  Assert(aCommandType in [gicArmyAttackUnit]);
  TakeCommand(MakeCommand(aCommandType, aGroup.UID, aUnit.UID));
end;


procedure TKMGameInputProcess.CmdArmy(aCommandType: TKMGameInputCommandType; aGroup1, aGroup2: TKMUnitGroup);
begin
  Assert(aCommandType in [gicArmyLink]);
  TakeCommand(MakeCommand(aCommandType, aGroup1.UID, aGroup2.UID));
end;


procedure TKMGameInputProcess.CmdArmy(aCommandType: TKMGameInputCommandType; aGroup: TKMUnitGroup; aHouse: TKMHouse);
begin
  Assert(aCommandType = gicArmyAttackHouse);
  TakeCommand(MakeCommand(aCommandType, aGroup.UID, aHouse.UID));
end;


procedure TKMGameInputProcess.CmdArmy(aCommandType: TKMGameInputCommandType; aGroup: TKMUnitGroup; aTurnAmount: TKMTurnDirection; aLineAmount:shortint);
begin
  Assert(aCommandType = gicArmyFormation);
  TakeCommand(MakeCommand(aCommandType, aGroup.UID, Byte(aTurnAmount), aLineAmount));
end;


procedure TKMGameInputProcess.CmdArmy(aCommandType: TKMGameInputCommandType; aGroup: TKMUnitGroup; const aLoc: TKMPoint; aDirection: TKMDirection);
begin
  Assert(aCommandType = gicArmyWalk);
  TakeCommand(MakeCommand(aCommandType, aGroup.UID, aLoc.X, aLoc.Y, Byte(aDirection)));
end;


procedure TKMGameInputProcess.CmdUnit(aCommandType: TKMGameInputCommandType; aUnit: TKMUnit);
begin
  Assert(aCommandType in [gicUnitDismiss, gicUnitDismissCancel]);
  TakeCommand(MakeCommand(aCommandType, aUnit.UID));
end;


procedure TKMGameInputProcess.CmdBuild(aCommandType: TKMGameInputCommandType; const aLoc: TKMPoint);
begin
  Assert(aCommandType in [gicBuildRemoveFieldPlan, gicBuildRemoveHouse, gicBuildRemoveHousePlan]);

  if gGameParams.IsReplayOrSpectate then Exit;

  //Remove fake markup that will be visible only to gMySpectator until Server verifies it.
  //Must go before TakeCommand as it could execute command immediately (in singleplayer)
  //and the fake markup must be added first otherwise our logic in FieldsList fails
  if gGameParams.IsMultiplayerGame and (aCommandType = gicBuildRemoveFieldPlan) then
    gMySpectator.Hand.RemFakeFieldPlan(aLoc);

  TakeCommand(MakeCommand(aCommandType, aLoc.X, aLoc.Y));
end;


procedure TKMGameInputProcess.CmdBuild(aCommandType: TKMGameInputCommandType; const aLoc: TKMPoint; aFieldType: TKMFieldType);
begin
  Assert(aCommandType in [gicBuildToggleFieldPlan]);

  if gGameParams.IsReplayOrSpectate then Exit;

  //Add fake markup that will be visible only to gMySpectator until Server verifies it.
  //Must go before TakeCommand as it could execute command immediately (in singleplayer)
  //and the fake markup must be added first otherwise our logic in FieldsList fails
  if gGameParams.IsMultiplayerGame then
    gMySpectator.Hand.ToggleFakeFieldPlan(aLoc, aFieldType);

  TakeCommand(MakeCommand(aCommandType, aLoc.X, aLoc.Y, Byte(aFieldType)));
end;


procedure TKMGameInputProcess.CmdBuild(aCommandType: TKMGameInputCommandType; const aLoc: TKMPoint; aHouseType: TKMHouseType);
begin
  Assert(aCommandType = gicBuildHousePlan);

  if gGameParams.IsReplayOrSpectate then Exit;

  TakeCommand(MakeCommand(aCommandType, Byte(aHouseType), aLoc.X, aLoc.Y));
end;


procedure TKMGameInputProcess.CmdHouse(aCommandType: TKMGameInputCommandType; aHouse: TKMHouse);
begin
  Assert(aCommandType in [gicHouseRepairToggle, gicHouseClosedForWorkerTgl, gicHBarracksAcceptRecruitsTgl, gicHouseDeliveryModeNext, gicHouseDeliveryModePrev]);
  TakeCommand(MakeCommand(aCommandType, aHouse.UID));
end;


procedure TKMGameInputProcess.CmdHouse(aCommandType: TKMGameInputCommandType; aHouse: TKMHouse; aItem, aAmountChange: Integer);
begin
  Assert(aCommandType in [gicHouseOrderProduct, gicHouseSchoolTrainChOrder]);
  TakeCommand(MakeCommand(aCommandType, aHouse.UID, aItem, aAmountChange));
end;


procedure TKMGameInputProcess.CmdHouse(aCommandType: TKMGameInputCommandType; aHouse: TKMHouse; aWareType: TKMWareType);
begin
  Assert(aCommandType in [gicHouseStoreNotAcceptFlag, gicHStoreNotAllowTakeOutFlag,
                          gicHouseBarracksAcceptFlag, gicHBarracksNotAllowTakeOutFlag,
                          gicHouseMarketFrom, gicHouseMarketTo, gicHouseArmorWSDeliveryToggle]);
  TakeCommand(MakeCommand(aCommandType, aHouse.UID, Byte(aWareType)));
end;


procedure TKMGameInputProcess.CmdHouse(aCommandType: TKMGameInputCommandType; aHouse: TKMHouse; aWoodcutterMode: TKMWoodcutterMode);
begin
  Assert(aCommandType = gicHouseWoodcutterMode);
  TakeCommand(MakeCommand(aCommandType, aHouse.UID, Byte(aWoodcutterMode)));
end;


procedure TKMGameInputProcess.CmdHouse(aCommandType: TKMGameInputCommandType; aHouse: TKMHouse; aUnitType: TKMUnitType; aCount: Integer);
begin
  Assert(aCommandType in [gicHouseSchoolTrain, gicHouseBarracksEquip, gicHouseTownHallEquip]);
  TakeCommand(MakeCommand(aCommandType, aHouse.UID, Byte(aUnitType), aCount));
end;


procedure TKMGameInputProcess.CmdHouse(aCommandType: TKMGameInputCommandType; aHouse: TKMHouse; aValue: Integer);
begin
  Assert(aCommandType in [gicHouseRemoveTrain, gicHouseSchoolTrainChLastUOrder, gicHouseTownHallMaxGold]);
  Assert((aHouse is TKMHouseSchool) or (aHouse is TKMHouseTownHall));
  TakeCommand(MakeCommand(aCommandType, aHouse.UID, aValue));
end;


procedure TKMGameInputProcess.CmdHouse(aCommandType: TKMGameInputCommandType; aHouse: TKMHouse; const aLoc: TKMPoint);
begin
  Assert((aCommandType = gicHouseBarracksRally) or (aCommandType = gicHouseTownHallRally) or (aCommandType = gicHouseWoodcuttersCutting));
  Assert((aHouse is TKMHouseBarracks) or (aHouse is TKMHouseTownHall) or (aHouse is TKMHouseWoodcutters));
  TakeCommand(MakeCommand(aCommandType, aHouse.UID, aLoc.X, aLoc.Y));
end;


procedure TKMGameInputProcess.CmdWareDistribution(aCommandType: TKMGameInputCommandType; aWare: TKMWareType; aHouseType: TKMHouseType; aValue:integer);
begin
  Assert(aCommandType = gicWareDistributionChange);
  TakeCommand(MakeCommand(aCommandType, Byte(aWare), Byte(aHouseType), aValue));
end;


procedure TKMGameInputProcess.CmdWareDistribution(aCommandType: TKMGameInputCommandType; const aTextParam: UnicodeString);
begin
  Assert(aCommandType = gicWareDistributions);
  TakeCommand(MakeCommand(aCommandType, aTextParam));
end;


procedure TKMGameInputProcess.CmdConsoleCommand(aCommandType: TKMGameInputCommandType; const aAnsiTxtParam: AnsiString;
                                                const aUniTxtArray: TKMScriptCommandParamsArray);
begin
  Assert(aCommandType = gicScriptConsoleCommand);
  TakeCommand(MakeCommand(aCommandType, aAnsiTxtParam, aUniTxtArray));
end;


procedure TKMGameInputProcess.CmdGame(aCommandType: TKMGameInputCommandType; aDateTime: TDateTime);
begin
  Assert(aCommandType in [gicGameAutoSave, gicGameAutoSaveAfterPT, gicGameSaveReturnLobby]);
  TakeCommand(MakeCommand(aCommandType, aDateTime));
end;


procedure TKMGameInputProcess.CmdGame(aCommandType: TKMGameInputCommandType; aParam1, aParam2: Integer);
begin
  Assert(aCommandType in [gicGameTeamChange, gicGameHotkeySet]);
  TakeCommand(MakeCommand(aCommandType, aParam1, aParam2));
end;


procedure TKMGameInputProcess.CmdGame(aCommandType: TKMGameInputCommandType; aValue: Integer);
begin
  Assert(aCommandType in [gicGameMessageLogRead, gicGamePlayerDefeat, gicGameLoadSave]);
  TakeCommand(MakeCommand(aCommandType, aValue));
end;


procedure TKMGameInputProcess.CmdGame(aCommandType: TKMGameInputCommandType; const aLoc: TKMPointF; aOwner: TKMHandID; aColor: Cardinal);
begin
  Assert(aCommandType = gicGameAlertBeacon);
  TakeCommand(MakeCommand(aCommandType, Round(aLoc.X * 10), Round(aLoc.Y * 10), aOwner, (aColor and $FFFFFF)));
end;


procedure TKMGameInputProcess.CmdGame(aCommandType: TKMGameInputCommandType; aValue: Single);
begin
  Assert(aCommandType = gicGameSpeed);
  TakeCommand(MakeCommandNoHand(aCommandType, aValue));
end;


procedure TKMGameInputProcess.CmdPlayerAllianceSet(aForPlayer, aToPlayer: TKMHandID; aAllianceType: TKMAllianceType);
begin
  TakeCommand(MakeCommand(gicGamePlayerAllianceSet, aForPlayer, aToPlayer, Byte(aAllianceType)));
end;


procedure TKMGameInputProcess.CmdPlayerAddDefaultGoals(aPlayer: TKMHandID; aBuilding: Boolean);
begin
  TakeCommand(MakeCommand(gicGamePlayerAddDefGoals, aPlayer, Byte(aBuilding)));
end;


procedure TKMGameInputProcess.CmdPlayerChanged(aPlayer: TKMHandID; aType: TKMHandType; aPlayerNikname: AnsiString);
begin
  Assert(ReplayState = gipRecording);
  TakeCommand(MakeCommand(gicGamePlayerChange, aPlayerNikname, aPlayer, Byte(aType)));
end;


procedure TKMGameInputProcess.CmdScriptSoundRemoveRequest(aScriptSoundUID: Integer);
begin
  TakeCommand(MakeCommand(gicScriptSoundRemoveRq, aScriptSoundUID));
end;


procedure TKMGameInputProcess.CmdTemp(aCommandType: TKMGameInputCommandType; const aLoc: TKMPoint);
begin
  Assert(aCommandType = gicTempAddScout);
  TakeCommand(MakeCommand(aCommandType, aLoc.X, aLoc.Y));
end;


procedure TKMGameInputProcess.CmdTemp(aCommandType: TKMGameInputCommandType);
begin
  Assert(aCommandType in [gicTempRevealMap, gicTempVictory, gicTempDefeat, gicTempDoNothing]);
  TakeCommand(MakeCommand(aCommandType));
end;


procedure TKMGameInputProcess.SaveToStream(SaveStream: TKMemoryStream);
var
  I: Integer;
begin
  SaveStream.WriteA(GAME_REVISION);
  SaveStream.Write(fCount);

  SaveExtra(SaveStream);

  for I := 1 to fCount do
  begin
    SaveStream.Write(fQueue[I].Tick);
    SaveCommandToMemoryStream(fQueue[I].Command, SaveStream);
    SaveStream.Write(fQueue[I].Rand);
  end;
end;


procedure TKMGameInputProcess.SaveToFile(const aFileName: UnicodeString);
var
  S: TKMemoryStreamBinary;
begin
  S := TKMemoryStreamBinary.Create;
  try
    SaveToStream(S);
    S.SaveToFileCompressed(aFileName, 'GIPCompressed');
  finally
    S.Free;
  end;
end;


procedure TKMGameInputProcess.SaveToFileAsync(const aFileName: UnicodeString; aWorkerThread: TKMWorkerThread);
var
  S: TKMemoryStreamBinary;
begin
  S := TKMemoryStreamBinary.Create;
  SaveToStream(S);
  TKMemoryStream.AsyncSaveToFileCompressedAndFree(S, aFileName, 'GIPCompressed', aWorkerThread);
end;


procedure TKMGameInputProcess.LoadFromStream(LoadStream: TKMemoryStream);
var
  I: Integer;
  fileVersion: AnsiString;
begin
  LoadStream.ReadA(fileVersion);
  //We could allow to load unsupported version files
  Assert(ALLOW_LOAD_UNSUP_VERSION_SAVE or (fileVersion = GAME_REVISION),
         'Old or unexpected replay file. ' + UnicodeString(GAME_REVISION) + ' is required.');

  LoadStream.Read(fCount);
  SetLength(fQueue, fCount + 1);

  LoadExtra(LoadStream);

  for I := 1 to fCount do
  begin
    LoadStream.Read(fQueue[I].Tick);
    LoadCommandFromMemoryStream(fQueue[I].Command, LoadStream);
    LoadStream.Read(fQueue[I].Rand);
  end;
end;


procedure TKMGameInputProcess.LoadFromFile(const aFileName: UnicodeString);
var
  S: TKMemoryStreamBinary;
begin
  if not FileExists(aFileName) then Exit;

  S := TKMemoryStreamBinary.Create;
  try
    S.LoadFromFileCompressed(aFileName, 'GIPCompressed');
    LoadFromStream(S);
  finally
    S.Free;
  end;
end;


{ Return last recorded tick }
function TKMGameInputProcess.GetLastTick: Cardinal;
begin
  Result := fQueue[fCount].Tick;
end;


{ See if replay has ended (no more commands in queue) }
function TKMGameInputProcess.ReplayEnded: Boolean;
begin
  Result := (ReplayState = gipReplaying) and (fCursor > fCount);
end;


//Store commands for the replay
//While in replay there are no commands to process, but for debug we might allow ChangePlayer
procedure TKMGameInputProcess.StoreCommand(const aCommand: TKMGameInputCommand);
begin
  if ReplayState = gipReplaying then
    Exit;

  Assert(ReplayState = gipRecording);
  Inc(fCount);
  if Length(fQueue) <= fCount then SetLength(fQueue, fCount + 128);

  fQueue[fCount].Tick    := gGameParams.Tick;
  fQueue[fCount].Command := aCommand;
  //Skip random check generation. We do not want KaMRandom to be called here
  if SKIP_RNG_CHECKS_FOR_SOME_GIC and (aCommand.CommandType in SKIP_RANDOM_CHECKS_FOR) then
    fQueue[fCount].Rand := 0
  else
    //This will be our check to ensure everything is consistent
    fQueue[fCount].Rand := Cardinal(KaMRandom(MaxInt, 'TKMGameInputProcess.StoreCommand'));
end;


procedure TKMGameInputProcess.ReplayTimer(aTick: Cardinal);
begin
end;


procedure TKMGameInputProcess.RunningTimer(aTick: Cardinal);
begin
end;


procedure TKMGameInputProcess.TakePlannedCommands;
var
  I: Integer;
begin
  if Self = nil then Exit;
  if fPlannedCommands.Count = 0 then Exit;

  // Take all planned commands
  for I := 0 to fPlannedCommands.Count - 1 do
    DoTakeCommand(fPlannedCommands[I]);

  // And clear
  fPlannedCommands.Clear;
end;


procedure TKMGameInputProcess.UpdateState(aTick: Cardinal);
begin
  //Only used in GIP_Multi
end;


function TKMGameInputProcess.IsLastTickValueCorrect(aLastTickValue: Cardinal): Boolean;
begin
  Result := aLastTickValue <> NO_LAST_TICK_VALUE;
end;


procedure TKMGameInputProcess.SaveExtra(SaveStream: TKMemoryStream);
begin
  SaveStream.Write(Cardinal(NO_LAST_TICK_VALUE));
end;


procedure TKMGameInputProcess.LoadExtra(LoadStream: TKMemoryStream);
var
  Tmp: Cardinal;
begin
  LoadStream.Read(Tmp); //Just read some bytes from the stream
  //Only used in GIP_Single
end;


function TKMGameInputProcess.QueueToString: String;
const
  MAX_ITEMS_CNT = 100;
var
  I, K, maxIndex: Integer;
begin
  if Self = nil then Exit('');

  if fReplayState = gipRecording then
    maxIndex := fCount
  else
    maxIndex := Min(fCount, fCursor);

  Result := '';
  K := 0;
  for I := maxIndex downto 1 do
  begin
    if not DoSkipLogCommand(fQueue[I].Command) then
    begin
      Inc(K);
      Result := Result + StoredGIPCommandToString(fQueue[I]) + '|';
    end;
    if K > MAX_ITEMS_CNT then
      Break;
  end;
end;


procedure TKMGameInputProcess.Paint;
var
  W: Integer;
  str: string;
  textSize: TKMPoint;
begin
  if Self = nil then Exit;
  if not SHOW_GIP then Exit;

  str := QueueToString;

  if str = '' then Exit;

  textSize := gRes.Fonts[fntMini].GetTextSize(str, False, False, TAB_WIDTH, True);

  W := gGame.ActiveInterface.MyControls.MasterPanel.Width;

  TKMRenderUI.WriteBevel(W - textSize.X - 10, 0, textSize.X + 10, textSize.Y + 10);
  TKMRenderUI.WriteText(W - textSize.X - 5, 0, 0, str, fntMini, taLeft, icWhite, False, False, False, TAB_WIDTH, True, True);
end;


function TKMGameInputProcess.StoredGIPCommandToString(aCommand: TKMStoredGIPCommand): String;
begin
  Result := Format('Tick %6d Rand %10d Cmd: %s', [aCommand.Tick, aCommand.Rand, GIPCommandToString(aCommand.Command)]);
end;


function GetGICCommandTypeMaxLength: Byte;
var
  cmd: TKMGameInputCommandType;
  len: Byte;
begin
  Result := 0;
  for cmd := Low(TKMGameInputCommandType) to High(TKMGameInputCommandType) do
  begin
    len := Length(GetEnumName(TypeInfo(TKMGameInputCommandType), Integer(cmd)));
    if len > Result then
      Result := len;
  end;
end;


initialization
begin
  GIC_COMMAND_TYPE_MAX_LENGTH := GetGICCommandTypeMaxLength;
end;


end.

