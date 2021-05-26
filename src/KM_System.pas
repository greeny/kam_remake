unit KM_System;
{$I KaM_Remake.inc}
interface
uses
  {$IFDEF MSWindows} Windows, {$ENDIF}
  {$IFDEF Unix} LCLIntf, LCLType, {$ENDIF}
  KM_ResSprites, KM_ResTypes,
  KM_Defaults;


type
  // System related features are encapsulated in this class
  TKMSystem = class
  private
    {$IFNDEF FPC}{$IFDEF MSWindows}
    fFormMainHandle: HWND;
    fFlashing: Boolean;
    {$ENDIF}{$ENDIF}

    function GetCursor: TKMCursor;
    procedure SetCursor(Value: TKMCursor);
  public
    constructor Create(aFormMainHandle: HWND);

    property Cursor: TKMCursor read GetCursor write SetCursor;

    procedure MakeCursors(aSprites: TKMSpritePack);

    procedure FlashingStart;
    procedure FlashingStop;
  end;


var
  gSystem: TKMSystem;


implementation
uses
  SysUtils, Math,
  Vcl.Forms, Vcl.Graphics;

const
  // Screen.Cursors[0] is used by System default cursor
  CURSOR_CNT_OFFSET = 1;

  // New custom cursors count
  CUSTOM_CUR_CNT = 1;

  CUSTOM_CURSORS: array [0..CUSTOM_CUR_CNT-1] of TKMCursor = (kmcAnimatedDirSelector);


{ TKMSystem }
constructor TKMSystem.Create(aFormMainHandle: HWND);
begin
  inherited Create;

  fFormMainHandle := aFormMainHandle;
end;


function TKMSystem.GetCursor: TKMCursor;
begin
  if InRange(Screen.Cursor - CURSOR_CNT_OFFSET, Ord(Low(TKMCursor)), Ord(High(TKMCursor))) then
    Result := TKMCursor(Screen.Cursor - CURSOR_CNT_OFFSET)
  else
    Result := kmcDefault;
end;


procedure TKMSystem.SetCursor(Value: TKMCursor);
begin
  if SKIP_LOADING_CURSOR then Exit;
  Screen.Cursor := Ord(Value) + CURSOR_CNT_OFFSET;
end;


procedure TKMSystem.MakeCursors(aSprites: TKMSpritePack);
const
  SF = 17; //Full width/height of a scroll cursor
  SH = 8; //Half width/height of a scroll cursor
  // Measured manually
  CURSOR_OFFSET_X: array [TKMCursor] of Integer = (0,0,20, 0, 0,-8, 9,0, 1,1,1,0,-1,-1,-1,0, SH,SF,SF,SF,SH, 0, 0,0, 0,0,0,27,0);
  CURSOR_OFFSET_Y: array [TKMCursor] of Integer = (0,9,10,18,20,44,13,0,-1,0,1,1, 1, 0,-1,0, 0 ,0 ,SH,SF,SF,SF,SH,0,28,0,0,28,0);

  CUSTOM_CUR_FILENAME: array[0..CUSTOM_CUR_CNT-1] of UnicodeString = ('cur1.ani');
var
  C: TKMCursor;
  I, sx, sy, x, y: Integer;
  bm, bm2: TBitmap;
  iconInfo: TIconInfo;
  Px: PRGBQuad;
  h : THandle;
  path: PChar;
  rxData: PRXData;
begin
  if SKIP_RENDER then Exit;

  rxData := @aSprites.RXData; // Store pointer to record instead of duplicating it

  bm  := TBitmap.Create; bm.HandleType  := bmDIB; bm.PixelFormat  := pf32bit;
  bm2 := TBitmap.Create; bm2.HandleType := bmDIB; bm2.PixelFormat := pf32bit;

  for C := Low(TKMCursor) to kmcPaintBucket do
  begin
    // Special case for invisible cursor
    if C = kmcInvisible then
    begin
      bm.Width  := 1; bm.Height  := 1;
      bm2.Width := 1; bm2.Height := 1;
      bm2.Canvas.Pixels[0,0] := clWhite; //Invisible mask, we don't care for Image color
      iconInfo.xHotspot := 0;
      iconInfo.yHotspot := 0;
    end
    else
    begin
      sx := rxData.Size[CURSOR_SPRITE_INDEX[C]].X;
      sy := rxData.Size[CURSOR_SPRITE_INDEX[C]].Y;
      bm.Width  := sx; bm.Height  := sy;
      bm2.Width := sx; bm2.Height := sy;

      for y := 0 to sy - 1 do
      begin
        Px := bm.ScanLine[y];
        for x := 0 to sx - 1 do
        begin
          if rxData.RGBA[CURSOR_SPRITE_INDEX[C],y*sx+x] and $FF000000 = 0 then
            Px.rgbReserved := $00
          else
            Px.rgbReserved := $FF;
          // Here we have BGR, not RGB
          Px.rgbBlue  := (rxData.RGBA[CURSOR_SPRITE_INDEX[C],y*sx+x] and $FF0000) shr 16;
          Px.rgbGreen := (rxData.RGBA[CURSOR_SPRITE_INDEX[C],y*sx+x] and $FF00) shr 8;
          Px.rgbRed   :=  rxData.RGBA[CURSOR_SPRITE_INDEX[C],y*sx+x] and $FF;
          Inc(Px);
        end;
      end;
      //Load hotspot offsets from RX file, adding the manual offsets (normally 0)
      iconInfo.xHotspot := Max(-rxData.Pivot[CURSOR_SPRITE_INDEX[C]].x + CURSOR_OFFSET_X[C], 0);
      iconInfo.yHotspot := Max(-rxData.Pivot[CURSOR_SPRITE_INDEX[C]].y + CURSOR_OFFSET_Y[C], 0);
    end;

    //Release the Mask, otherwise there is black rect in Lazarus
    //it works only from within the loop, means mask is recreated when we access canvas or something like that
    bm2.ReleaseMaskHandle;

    iconInfo.fIcon := false; //true=Icon, false=Cursor
    iconInfo.hbmColor := bm.Handle;

    //I have a suspicion that maybe Windows could create icon delayed, at a time when bitmap data is
    //no longer valid (replaced by other bitmap or freed). Hence issues with transparency.
    {$IFDEF MSWindows}
      iconInfo.hbmMask  := bm2.Handle;
      Screen.Cursors[Byte(C) + CURSOR_CNT_OFFSET] := CreateIconIndirect(iconInfo);
    {$ENDIF}
    {$IFDEF Unix}
      bm2.Mask(clWhite);
      IconInfo.hbmMask  := bm2.MaskHandle;
      Screen.Cursors[Byte(KMC) + COUNT_OFFSET] :=  CreateIconIndirect(@IconInfo);
    {$ENDIF}
  end;

  bm.Free;
  bm2.Free;

  for I := Low(CUSTOM_CURSORS) to High(CUSTOM_CURSORS) do
  begin
    path := PChar(ExeDir + 'data' + PathDelim + 'cursors' + PathDelim + CUSTOM_CUR_FILENAME[I]);
    h := LoadImage(0,
               path,
               IMAGE_CURSOR,
               35,
               36,
               LR_DEFAULTSIZE or
               LR_LOADFROMFILE);

    if h <> 0 then
      Screen.Cursors[Byte(CUSTOM_CURSORS[I]) + CURSOR_CNT_OFFSET] := h
    else
      // Use default cursor, in case of missing cursor file
      Screen.Cursors[Byte(CUSTOM_CURSORS[I]) + CURSOR_CNT_OFFSET] := Screen.Cursors[Byte(kmcDefault) + CURSOR_CNT_OFFSET];
  end;
end;


procedure TKMSystem.FlashingStart;
{$IFNDEF FPC}{$IFDEF MSWindows}
var
  flashInfo: TFlashWInfo;
{$ENDIF}{$ENDIF}
begin
  {$IFNDEF FPC}{$IFDEF MSWindows}
  if (GetForegroundWindow <> fFormMainHandle) then
  begin
    flashInfo.cbSize := 20;
    flashInfo.hwnd := Application.Handle;
    flashInfo.dwflags := FLASHW_ALL;
    flashInfo.ucount := 5; // Flash 5 times
    flashInfo.dwtimeout := 0; // Use default cursor blink rate
    fFlashing := True;
    FlashWindowEx(flashInfo);
  end
  {$ENDIF}{$ENDIF}
end;


procedure TKMSystem.FlashingStop;
{$IFNDEF FPC}{$IFDEF MSWindows}
var
  flashInfo: TFlashWInfo;
{$ENDIF}{$ENDIF}
begin
  {$IFNDEF FPC}{$IFDEF MSWindows}
  if fFlashing then
  begin
    flashInfo.cbSize := 20;
    flashInfo.hwnd := Application.Handle;
    flashInfo.dwflags := FLASHW_STOP;
    flashInfo.ucount := 0;
    flashInfo.dwtimeout := 0;
    fFlashing := False;
    FlashWindowEx(flashInfo);
  end
  {$ENDIF}{$ENDIF}
end;


end.
