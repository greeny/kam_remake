unit KM_RenderTerrain;
{$I KaM_Remake.inc}
interface
uses
  dglOpenGL, SysUtils, KromUtils, Math,
  KM_CommonClasses, KM_Defaults, KM_FogOfWar, KM_Pics, KM_ResourceSprites, KM_Points, KM_Terrain;

type
  TUVRect = array [1 .. 4, 1 .. 2] of Single; // Texture UV coordinates
  TVertice = record
    X, Y, Z, ULit, UShd: Single;
  end;

  //Render terrain without sprites
  TRenderTerrain = class
  private
    fRect: TKMRect;
    fFOW: TKMFogOfWar;
    fTextG: GLuint; //Shading gradient for lighting
    fUseVBO: Boolean; //Wherever to render terrain through VBO (faster but needs GL1.5) or DrawCalls (slower but needs only GL1.1)
    fPos: array of TVertice;
    fInd: array of Integer;
    fVtxShd: GLUint;
    fIndShd: GLUint;
    function GetTileUV(Index: Word; Rot: Byte): TUVRect;
    procedure BeginVBO;
    procedure EndVBO;
    procedure DoTiles;
    procedure DoOverlays;
    procedure DoFences;
    procedure DoMarks(aFieldsList: TKMPointTagList; aHousePlansList: TKMPointDirList);
    procedure DoLighting;
    procedure DoWater(AnimStep: Integer);
    procedure DoShadows;
    function VBOSupported: Boolean;
    procedure RenderFence(aFence: TFenceType; Pos: TKMDirection; pX,pY: Integer);
    procedure RenderMarkup(pX, pY: Word; aFieldType: TFieldType);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Render(aRect: TKMRect; AnimStep: Integer; aFOW: TKMFogOfWar; aFieldsList: TKMPointTagList; aHousePlansList: TKMPointDirList);
    procedure RenderTile(Index: Byte; pX,pY,Rot: Integer);
  end;


implementation
uses KM_Render, KM_RenderAux;


constructor TRenderTerrain.Create;
var
  I: Integer;
  pData: array [0..255] of Cardinal;
begin
  inherited;
  if SKIP_RENDER then Exit;

  //Generate gradient programmatically
  //KaM uses [0..255] gradients
  //We use slightly smoothed gradients [16..255] for Remake
  //cos it shows much more of terrain on screen and it looks too contrast
  for I := 0 to 255 do
    pData[I] := EnsureRange(Round(I * 1.0625 - 16), 0, 255) * 65793 or $FF000000;

  fTextG := TRender.GenTexture(256, 1, @pData[0], tf_RGBA8);

  fUseVBO := VBOSupported;

  if fUseVBO then
  begin
    glGenBuffers(1, @fVtxShd);
    glGenBuffers(1, @fIndShd);
  end;
end;


destructor TRenderTerrain.Destroy;
begin
  fUseVBO := VBOSupported; //Could have been set to false if 3D rendering is enabled, so reset it
  if fUseVBO then
  begin
    //Since RenderTerrain is created fresh everytime fGame is created, we should clear
    //the buffers to avoid memory leaks.
    glDeleteBuffers(1, @fVtxShd);
    glDeleteBuffers(1, @fIndShd);
  end;
  Inherited;
end;


function TRenderTerrain.VBOSupported:Boolean;
begin
  //Some GPUs don't comply with OpenGL 1.5 spec on VBOs, so check Assigned instead of GL_VERSION_1_5
  Result := Assigned(glGenBuffers)        and Assigned(glBindBuffer)    and Assigned(glBufferData) and
            Assigned(glEnableClientState) and Assigned(glVertexPointer) and Assigned(glClientActiveTexture) and
            Assigned(glTexCoordPointer)   and Assigned(glDrawElements)  and Assigned(glDisableClientState) and
            Assigned(glDeleteBuffers);
end;


function TRenderTerrain.GetTileUV(Index: Word; Rot: Byte): TUVRect;
var
  TexO: array [1 .. 4] of Byte; // order of UV coordinates, for rotations
  A: Byte;
begin
  TexO[1] := 1;
  TexO[2] := 2;
  TexO[3] := 3;
  TexO[4] := 4;

  // Rotate by 90 degrees: 4-1-2-3
  if Rot and 1 = 1 then
  begin
    A := TexO[4];
    TexO[4] := TexO[3];
    TexO[3] := TexO[2];
    TexO[2] := TexO[1];
    TexO[1] := A;
  end;

  //Rotate by 180 degrees: 3-4-1-2
  if Rot and 2 = 2 then
  begin
    SwapInt(TexO[1], TexO[3]);
    SwapInt(TexO[2], TexO[4]);
  end;

  with GFXData[rxTiles, Index+1] do
  begin
    Result[TexO[1], 1] := Tex.u1; Result[TexO[1], 2] := Tex.v1;
    Result[TexO[2], 1] := Tex.u1; Result[TexO[2], 2] := Tex.v2;
    Result[TexO[3], 1] := Tex.u2; Result[TexO[3], 2] := Tex.v2;
    Result[TexO[4], 1] := Tex.u2; Result[TexO[4], 2] := Tex.v1;
  end;
end;


procedure TRenderTerrain.BeginVBO;
var
  I,K,H: Integer;
  SizeX, SizeY: Word;
  tX, tY: Word;
  Row: Integer;
begin
  if not fUseVBO then Exit;

  SizeX := fRect.Right - fRect.Left;
  SizeY := fRect.Bottom - fRect.Top;
  H := 0;
  SetLength(fPos, (SizeX + 2) * 2 * (SizeY + 1));
  with fTerrain do
  if (MapX > 0) and (MapY > 0) then
  for I := 0 to SizeY do
  for K := 0 to SizeX+1 do
  begin
    tX := K + fRect.Left;
    tY := I + fRect.Top;
    fPos[H+0].X := tX-1;
    fPos[H+0].Y := tY-1 - Land[tY, tX].Height / CELL_HEIGHT_DIV;
    fPos[H+0].Z := -tY;
    fPos[H+0].ULit := Land[tY, tX].Light;
    fPos[H+0].UShd := max(-Land[tY, tX].Light, 1 - fFOW.CheckVerticeRevelation(tX-1, tY-1, True) / 255);

    tY := I + fRect.Top + 1;
    fPos[H+1].X := tX-1;
    fPos[H+1].Y := tY-1 - Land[tY, tX].Height / CELL_HEIGHT_DIV;
    fPos[H+1].Z := -tY + 1;
    fPos[H+1].ULit := Land[tY, tX].Light;
    fPos[H+1].UShd := max(-Land[tY, tX].Light, 1 - fFOW.CheckVerticeRevelation(tX-1, tY-1, True) / 255);
    H := H + 2;
  end;

  H := 0;
  SetLength(fInd, (SizeX+1) * (SizeY+1) * 6);
  for I := 0 to SizeY do
  for K := 0 to SizeX do
  begin
    Row := I * (SizeX + 2) * 2;
    fInd[H+0] := Row + K * 2;
    fInd[H+1] := Row + K * 2 + 1;
    fInd[H+2] := Row + K * 2 + 3;
    fInd[H+3] := Row + K * 2;
    fInd[H+4] := Row + K * 2 + 3;
    fInd[H+5] := Row + K * 2 + 2;
    H := H + 6;
  end;

  glBindBuffer(GL_ARRAY_BUFFER, fVtxShd);
  glBufferData(GL_ARRAY_BUFFER, Length(fPos) * SizeOf(TVertice), @fPos[0].X, GL_STREAM_DRAW);

  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, fIndShd);
  glBufferData(GL_ELEMENT_ARRAY_BUFFER, Length(fInd) * SizeOf(fInd[0]), @fInd[0], GL_STREAM_DRAW);
end;


procedure TRenderTerrain.EndVBO;
begin
  if not fUseVBO then Exit;

  glBindBuffer(GL_ARRAY_BUFFER, 0);
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
end;


procedure TRenderTerrain.DoTiles;
var
  TexC: TUVRect;
  I,K: Integer;
begin
  //First we render base layer, then we do animated layers for Water/Swamps/Waterfalls
  //They all run at different speeds so we can't adjoin them in one layer

  with fTerrain do
  for I := fRect.Top to fRect.Bottom do
  for K := fRect.Left to fRect.Right do
  begin
    glBindTexture(GL_TEXTURE_2D, GFXData[rxTiles, Land[I,K].Terrain+1].Tex.ID);
    glBegin(GL_TRIANGLE_FAN);
    TexC := GetTileUV(Land[I,K].Terrain, Land[I,K].Rotation);

    glColor4f(1,1,1,1);
    if RENDER_3D then
    begin
      glTexCoord2fv(@TexC[1]); glVertex3f(K-1,I-1,-Land[I,K].Height/CELL_HEIGHT_DIV);
      glTexCoord2fv(@TexC[2]); glVertex3f(K-1,I  ,-Land[I+1,K].Height/CELL_HEIGHT_DIV);
      glTexCoord2fv(@TexC[3]); glVertex3f(K  ,I  ,-Land[I+1,K+1].Height/CELL_HEIGHT_DIV);
      glTexCoord2fv(@TexC[4]); glVertex3f(K  ,I-1,-Land[I,K+1].Height/CELL_HEIGHT_DIV);
    end else begin
      glTexCoord2fv(@TexC[1]); glVertex3f(K-1,I-1-Land[I,K].Height / CELL_HEIGHT_DIV, -I);
      glTexCoord2fv(@TexC[2]); glVertex3f(K-1,I  -Land[I+1,K].Height / CELL_HEIGHT_DIV, -I);
      glTexCoord2fv(@TexC[3]); glVertex3f(K  ,I  -Land[I+1,K+1].Height / CELL_HEIGHT_DIV, -I);
      glTexCoord2fv(@TexC[4]); glVertex3f(K  ,I-1-Land[I,K+1].Height / CELL_HEIGHT_DIV, -I);
    end;
    glEnd;
  end;
end;


procedure TRenderTerrain.DoWater(AnimStep: Integer);
type TAnimLayer = (alWater, alFalls, alSwamp);
var
  AL: TAnimLayer;
  I,K: Integer;
  TexC: TUVRect;
  TexOffset: Word;
begin
  //First we render base layer, then we do animated layers for Water/Swamps/Waterfalls
  //They all run at different speeds so we can't adjoin them in one layer
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

  //Each new layer inflicts 10% fps drop
  for AL := Low(TAnimLayer) to High(TAnimLayer) do
  begin
    case AL of
      alWater: TexOffset := 300 * (AnimStep mod 8 + 1);       // 300..2400
      alFalls: TexOffset := 300 * (AnimStep mod 5 + 1 + 8);   // 2700..3900
      alSwamp: TexOffset := 300 * ((AnimStep mod 24) div 8 + 1 + 8 + 5); // 4200..4800
      else     TexOffset := 0;
    end;

    with fTerrain do
    for I := fRect.Top to fRect.Bottom do
    for K := fRect.Left to fRect.Right do
    if (TexOffset + Land[I,K].Terrain + 1 <= High(GFXData[rxTiles]))
    and (GFXData[rxTiles, TexOffset + Land[I,K].Terrain + 1].Tex.ID <> 0)
    and (fFOW.CheckTileRevelation(K,I,true) > FOG_OF_WAR_ACT) then //No animation in FOW
    begin
      glBindTexture(GL_TEXTURE_2D, GFXData[rxTiles, TexOffset + Land[I,K].Terrain + 1].Tex.ID);
      TexC := GetTileUV(TexOffset + Land[I,K].Terrain, Land[I,K].Rotation);

      glBegin(GL_TRIANGLE_FAN);
        glColor4f(1,1,1,1);
        if RENDER_3D then begin
          glTexCoord2fv(@TexC[1]); glVertex3f(K-1,I-1,-Land[I,K].Height/CELL_HEIGHT_DIV);
          glTexCoord2fv(@TexC[2]); glVertex3f(K-1,I  ,-Land[I+1,K].Height/CELL_HEIGHT_DIV);
          glTexCoord2fv(@TexC[3]); glVertex3f(K  ,I  ,-Land[I+1,K+1].Height/CELL_HEIGHT_DIV);
          glTexCoord2fv(@TexC[4]); glVertex3f(K  ,I-1,-Land[I,K+1].Height/CELL_HEIGHT_DIV);
        end else begin
          glTexCoord2fv(@TexC[1]); glVertex3f(K-1,I-1-Land[I,K].Height/CELL_HEIGHT_DIV, -I);
          glTexCoord2fv(@TexC[2]); glVertex3f(K-1,I  -Land[I+1,K].Height/CELL_HEIGHT_DIV, -I);
          glTexCoord2fv(@TexC[3]); glVertex3f(K  ,I  -Land[I+1,K+1].Height/CELL_HEIGHT_DIV, -I);
          glTexCoord2fv(@TexC[4]); glVertex3f(K  ,I-1-Land[I,K+1].Height/CELL_HEIGHT_DIV, -I);
        end;
      glEnd;
    end;
  end;
end;


procedure TRenderTerrain.DoOverlays;
//   1      //Select road tile and rotation
//  8*2     //depending on surrounding tiles
//   4      //Bitfield
const
  RoadsConnectivity: array [0..15, 1..2] of Byte = (
    (248,0), (248,0), (248,1), (250,3),
    (248,0), (248,0), (250,0), (252,0),
    (248,1), (250,2), (248,1), (252,3),
    (250,1), (252,2), (252,1), (254,0));
var
  I, K: Integer;
  Road, ID, Rot: Byte;
begin
  glColor4f(1, 1, 1, 1);

  for I := fRect.Top to fRect.Bottom do
  for K := fRect.Left to fRect.Right do
  case fTerrain.Land[I, K].TileOverlay of
    to_Dig1:  RenderTile(249, K, I, 0);
    to_Dig2:  RenderTile(251, K, I, 0);
    to_Dig3:  RenderTile(253, K, I, 0);
    to_Dig4:  RenderTile(255, K, I, 0);
    to_Wall:  fRenderAux.Quad(K, I, $800000FF);
    to_Road:  begin
                Road := 0;
                if (I - 1 >= 1) then
                  Road := Road + byte(fTerrain.Land[I - 1, K].TileOverlay = to_Road) shl 0;
                if (K + 1 <= fTerrain.MapX - 1) then
                  Road := Road + byte(fTerrain.Land[I, K + 1].TileOverlay = to_Road) shl 1;
                if (I + 1 <= fTerrain.MapY - 1) then
                  Road := Road + byte(fTerrain.Land[I + 1, K].TileOverlay = to_Road) shl 2;
                if (K - 1 >= 1) then
                  Road := Road + byte(fTerrain.Land[I, K - 1].TileOverlay = to_Road) shl 3;
                ID := RoadsConnectivity[Road, 1];
                Rot := RoadsConnectivity[Road, 2];
                RenderTile(ID, K, I, Rot);
              end;
   end;
end;


procedure TRenderTerrain.DoFences;
var
  I,K: Integer;
begin
  //Disable depth test and write to depth buffer,
  //so that terrain shadows could be applied seamlessly ontop
  glDepthMask(False);
  glDisable(GL_DEPTH_TEST);

  with fTerrain do
  for I := fRect.Top to fRect.Bottom do
  for K := fRect.Left to fRect.Right do
  begin
    if Land[I,K].FenceSide and 1 = 1 then RenderFence(Land[I,K].Fence, dir_N, K, I);
    if Land[I,K].FenceSide and 2 = 2 then RenderFence(Land[I,K].Fence, dir_E, K, I);
    if Land[I,K].FenceSide and 4 = 4 then RenderFence(Land[I,K].Fence, dir_W, K, I);
    if Land[I,K].FenceSide and 8 = 8 then RenderFence(Land[I,K].Fence, dir_S, K, I);
  end;

  //Reenable depth test and write
  glDepthMask(True);
  glEnable(GL_DEPTH_TEST);
end;


//Player markings should be always clearly visible to the player (thats why we render them ontop FOW)
procedure TRenderTerrain.DoMarks(aFieldsList: TKMPointTagList; aHousePlansList: TKMPointDirList);
var
  I: Integer;
begin
  //Disable depth test and write to depth buffer,
  //so that terrain shadows could be applied seamlessly ontop
  glDepthMask(False);
  glDisable(GL_DEPTH_TEST);

  //Rope field marks
  for I := 0 to aFieldsList.Count - 1 do
    RenderMarkup(aFieldsList[I].X, aFieldsList[I].Y, TFieldType(aFieldsList.Tag[I]));

  //Rope outlines
  for I := 0 to aHousePlansList.Count - 1 do
    RenderFence(fncHousePlan, aHousePlansList[I].Dir, aHousePlansList[I].Loc.X, aHousePlansList[I].Loc.Y);

  //Reenable depth test and write
  glDepthMask(True);
  glEnable(GL_DEPTH_TEST);
end;


procedure TRenderTerrain.DoLighting;
var
  I, K: Integer;
begin
  glColor4f(1, 1, 1, 1);
  //Render highlights
  glBlendFunc(GL_DST_COLOR, GL_ONE);
  glBindTexture(GL_TEXTURE_2D, fTextG);

  if fUseVBO then
  begin
    //Setup vertex and UV layout and offsets
    glEnableClientState(GL_VERTEX_ARRAY);
    glVertexPointer(3, GL_FLOAT, SizeOf(TVertice), Pointer(0));
    glClientActiveTexture(GL_TEXTURE0);
    glEnableClientState(GL_TEXTURE_COORD_ARRAY);
    glTexCoordPointer(1, GL_FLOAT, SizeOf(TVertice), Pointer(12));

    //Here and above OGL requests Pointer, but in fact it's just a number (offset within Array)
    glDrawElements(GL_TRIANGLES, Length(fInd), GL_UNSIGNED_INT, Pointer(0));

    glDisableClientState(GL_VERTEX_ARRAY);
    glDisableClientState(GL_TEXTURE_COORD_ARRAY);
  end
  else
  begin
    with fTerrain do
    if RENDER_3D then
      for I := fRect.Top to fRect.Bottom do
      for K := fRect.Left to fRect.Right do
      begin
        glBegin(GL_TRIANGLE_FAN);
          glTexCoord1f(Land[  I,   K].Light); glVertex3f(K-1, I-1, -Land[  I,   K].Height / CELL_HEIGHT_DIV);
          glTexCoord1f(Land[I+1,   K].Light); glVertex3f(K-1,   I, -Land[I+1,   K].Height / CELL_HEIGHT_DIV);
          glTexCoord1f(Land[I+1, K+1].Light); glVertex3f(  K,   I, -Land[I+1, K+1].Height / CELL_HEIGHT_DIV);
          glTexCoord1f(Land[  I, K+1].Light); glVertex3f(  K, I-1, -Land[  I, K+1].Height / CELL_HEIGHT_DIV);
        glEnd;
      end
    else
      for I := fRect.Top to fRect.Bottom do
      for K := fRect.Left to fRect.Right do
      begin
        glBegin(GL_TRIANGLE_FAN);
          glTexCoord1f(Land[  I,   K].Light); glVertex3f(K-1, I-1 - Land[  I,   K].Height / CELL_HEIGHT_DIV, -I);
          glTexCoord1f(Land[I+1,   K].Light); glVertex3f(K-1,   I - Land[I+1,   K].Height / CELL_HEIGHT_DIV, -I);
          glTexCoord1f(Land[I+1, K+1].Light); glVertex3f(  K,   I - Land[I+1, K+1].Height / CELL_HEIGHT_DIV, -I);
          glTexCoord1f(Land[  I, K+1].Light); glVertex3f(  K, I-1 - Land[  I, K+1].Height / CELL_HEIGHT_DIV, -I);
        glEnd;
      end;
  end;
end;


//Render shadows and FOW at once
procedure TRenderTerrain.DoShadows;
var
  I,K: Integer;
begin
  glBlendFunc(GL_ZERO, GL_ONE_MINUS_SRC_COLOR);
  glBindTexture(GL_TEXTURE_2D, fTextG);

  if fUseVBO then
  begin
    //Setup vertex and UV layout and offsets
    glEnableClientState(GL_VERTEX_ARRAY);
    glVertexPointer(3, GL_FLOAT, SizeOf(TVertice), Pointer(0));
    glClientActiveTexture(GL_TEXTURE0);
    glEnableClientState(GL_TEXTURE_COORD_ARRAY);
    glTexCoordPointer(1, GL_FLOAT, SizeOf(TVertice), Pointer(16));

    //Here and above OGL requests Pointer, but in fact it's just a number (offset within Array)
    glDrawElements(GL_TRIANGLES, Length(fInd), GL_UNSIGNED_INT, Pointer(0));

    glDisableClientState(GL_VERTEX_ARRAY);
    glDisableClientState(GL_TEXTURE_COORD_ARRAY);
  end
  else
  begin
    with fTerrain do
    if RENDER_3D then
      for I := fRect.Top to fRect.Bottom do
      for K := fRect.Left to fRect.Right do
      begin
        glBegin(GL_TRIANGLE_FAN);
          glTexCoord1f(kromutils.max(0, -Land[I, K].Light, 1 - fFOW.CheckVerticeRevelation(K - 1, I - 1, true) / 255));
          glVertex3f(K - 1, I - 1, -Land[I, K].Height / CELL_HEIGHT_DIV);
          glTexCoord1f(kromutils.max(0, -Land[I + 1, K].Light, 1 - fFOW.CheckVerticeRevelation(K - 1, I, true) / 255));
          glVertex3f(K - 1, I, -Land[I + 1, K].Height / CELL_HEIGHT_DIV);
          glTexCoord1f(kromutils.max(0, -Land[I + 1, K + 1].Light, 1 - fFOW.CheckVerticeRevelation(K, I, true) / 255));
          glVertex3f(K, I, -Land[I + 1, K + 1].Height / CELL_HEIGHT_DIV);
          glTexCoord1f(kromutils.max(0, -Land[I, K + 1].Light, 1 - fFOW.CheckVerticeRevelation(K, I - 1, true) / 255));
          glVertex3f(K, I - 1, -Land[I, K + 1].Height / CELL_HEIGHT_DIV);
        glEnd;
      end
    else
      for I := fRect.Top to fRect.Bottom do
      for K := fRect.Left to fRect.Right do
      begin
        glBegin(GL_TRIANGLE_FAN);
          glTexCoord1f(max(-Land[I, K].Light, 1 - fFOW.CheckVerticeRevelation(K - 1, I - 1, true) / 255));
          glVertex3f(K - 1, I - 1 - Land[I, K].Height / CELL_HEIGHT_DIV, -I);
          glTexCoord1f(max(-Land[I + 1, K].Light, 1 - fFOW.CheckVerticeRevelation(K - 1, I, true) / 255));
          glVertex3f(K - 1, I - Land[I + 1, K].Height / CELL_HEIGHT_DIV, -I);
          glTexCoord1f(max(-Land[I + 1, K + 1].Light, 1 - fFOW.CheckVerticeRevelation(K, I, true) / 255));
          glVertex3f(K, I - Land[I + 1, K + 1].Height / CELL_HEIGHT_DIV, -I);
          glTexCoord1f(max(-Land[I, K + 1].Light, 1 - fFOW.CheckVerticeRevelation(K, I - 1, true) / 255));
          glVertex3f(K, I - 1 - Land[I, K + 1].Height / CELL_HEIGHT_DIV, -I);
        glEnd;
      end;
  end;

  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
  glBindTexture(GL_TEXTURE_2D, 0);
end;


//aRect - boundaries of render area in tilespace
//AnimStep - animation step for terrain (water/etc)
//aFOW - whose players FOW to apply
procedure TRenderTerrain.Render(aRect: TKMRect; AnimStep: Integer; aFOW: TKMFogOfWar; aFieldsList: TKMPointTagList; aHousePlansList: TKMPointDirList);
var
  I,K: Integer;
begin
  fRect := aRect;
  fFOW := aFOW;

  //VBO has proper vertice coords only for Light/Shadow
  //it cant handle 3D yet and because of FOW leaves terrain revealed, which is an exploit in MP
  //Thus we allow VBO only in 2D
  fUseVBO := VBOSupported and not RENDER_3D;

  glPushAttrib(GL_DEPTH_BUFFER_BIT);

    //With depth test we can render all terrain tiles and then apply light/shadow without worrying about
    //foothills shadows going over mountain tops. Each tile strip is rendered an next Z plane.
    //Means that Z-test on gpu will take care of clipping the foothill shadows
    glEnable(GL_DEPTH_TEST);
    glDepthFunc(GL_LEQUAL);

    BeginVBO;
      DoTiles;
      DoOverlays;
      DoLighting;
      DoWater(AnimStep); //Unlit water goes above lit sand
      DoFences;
      DoShadows;
      DoMarks(aFieldsList, aHousePlansList);
    EndVBO;

    if SHOW_WALK_CONNECT then
    begin
      glPushAttrib(GL_DEPTH_BUFFER_BIT);
        glDisable(GL_DEPTH_TEST);

        for I := aRect.Top to aRect.Bottom do
        for K := aRect.Left to aRect.Right do
          fRenderAux.Text(K, I, IntToStr(fTerrain.Land[I,K].WalkConnect[wcWalk]), $FFFFFFFF);

      glPopAttrib;
    end;

  glPopAttrib;
end;


//Render single terrian cell
procedure TRenderTerrain.RenderTile(Index: Byte; pX,pY,Rot: Integer);
var
  K, I: Integer;
  TexC: TUVRect; // Texture UV coordinates
begin
  if not fTerrain.TileInMapCoords(pX,pY) then Exit;

  K := pX;
  I := pY;
  glColor4f(1, 1, 1, 1);

  glBindTexture(GL_TEXTURE_2D, GFXData[rxTiles, Index + 1].Tex.ID);
  TexC := GetTileUV(Index, Rot);

  glBegin(GL_TRIANGLE_FAN);
    with fTerrain do
    if RENDER_3D then
    begin
      glTexCoord2fv(@TexC[1]); glVertex3f(k-1,i-1,-Land[i,k].Height/CELL_HEIGHT_DIV);
      glTexCoord2fv(@TexC[2]); glVertex3f(k-1,i  ,-Land[i+1,k].Height/CELL_HEIGHT_DIV);
      glTexCoord2fv(@TexC[3]); glVertex3f(k  ,i  ,-Land[i+1,k+1].Height/CELL_HEIGHT_DIV);
      glTexCoord2fv(@TexC[4]); glVertex3f(k  ,i-1,-Land[i,k+1].Height/CELL_HEIGHT_DIV);
    end
    else
    begin
      glTexCoord2fv(@TexC[1]); glVertex3f(k-1,i-1-Land[i,k].Height/CELL_HEIGHT_DIV, -i);
      glTexCoord2fv(@TexC[2]); glVertex3f(k-1,i  -Land[i+1,k].Height/CELL_HEIGHT_DIV, -i);
      glTexCoord2fv(@TexC[3]); glVertex3f(k  ,i  -Land[i+1,k+1].Height/CELL_HEIGHT_DIV, -i);
      glTexCoord2fv(@TexC[4]); glVertex3f(k  ,i-1-Land[i,k+1].Height/CELL_HEIGHT_DIV, -i);
    end;
  glEnd;
  glBindTexture(GL_TEXTURE_2D, 0);
end;


procedure TRenderTerrain.RenderFence(aFence: TFenceType; Pos: TKMDirection; pX,pY: Integer);
const
  FO = 4; //Fence overlap
  VO = -4; //Move fences a little down to avoid visible overlap when unit stands behind fence, but is rendered ontop of it, due to Z sorting algo we use
var
  UVa, UVb: TKMPointF;
  TexID: Integer;
  x1,x2,y1,y2,FenceX, FenceY: Single;
  HeightInPx: Integer;
begin
  case aFence of
    fncHouseFence: if Pos in [dir_N,dir_S] then TexID:=463 else TexID:=467; //WIP (Wood planks)
    fncHousePlan:  if Pos in [dir_N,dir_S] then TexID:=105 else TexID:=117; //Plan (Ropes)
    fncWine:       if Pos in [dir_N,dir_S] then TexID:=462 else TexID:=466; //Fence (Wood)
    fncCorn:       if Pos in [dir_N,dir_S] then TexID:=461 else TexID:=465; //Fence (Stones)
    else          TexID := 0;
  end;

  //With these directions render fences on next tile
  if Pos = dir_S then Inc(pY);
  if Pos = dir_W then Inc(pX);

  if Pos in [dir_N, dir_S] then
  begin //Horizontal
    glBindTexture(GL_TEXTURE_2D, GFXData[rxGui,TexID].Tex.ID);
    UVa.X := GFXData[rxGui, TexID].Tex.u1;
    UVa.Y := GFXData[rxGui, TexID].Tex.v1;
    UVb.X := GFXData[rxGui, TexID].Tex.u2;
    UVb.Y := GFXData[rxGui, TexID].Tex.v2;

    y1 := pY - 1 - (fTerrain.Land[pY, pX].Height + VO) / CELL_HEIGHT_DIV;
    y2 := pY - 1 - (fTerrain.Land[pY, pX + 1].Height + VO) / CELL_HEIGHT_DIV;

    FenceY := GFXData[rxGui,TexID].PxWidth / CELL_SIZE_PX;
    glBegin(GL_QUADS);
      glTexCoord2f(UVb.x, UVa.y); glVertex2f(pX-1 -3/ CELL_SIZE_PX, y1);
      glTexCoord2f(UVa.x, UVa.y); glVertex2f(pX-1 -3/ CELL_SIZE_PX, y1 - FenceY);
      glTexCoord2f(UVa.x, UVb.y); glVertex2f(pX   +3/ CELL_SIZE_PX, y2 - FenceY);
      glTexCoord2f(UVb.x, UVb.y); glVertex2f(pX   +3/ CELL_SIZE_PX, y2);
    glEnd;
  end
  else
  begin //Vertical
    glBindTexture(GL_TEXTURE_2D, GFXData[rxGui,TexID].Tex.ID);
    HeightInPx := Round(CELL_SIZE_PX * (1 + (fTerrain.Land[pY,pX].Height - fTerrain.Land[pY+1,pX].Height)/CELL_HEIGHT_DIV)+FO);
    UVa.X := GFXData[rxGui, TexID].Tex.u1;
    UVa.Y := GFXData[rxGui, TexID].Tex.v1;
    UVb.X := GFXData[rxGui, TexID].Tex.u2;
    UVb.Y := Mix(GFXData[rxGui, TexID].Tex.v2, GFXData[rxGui, TexID].Tex.v1, HeightInPx / GFXData[rxGui, TexID].pxHeight);

    y1 := pY - 1 - (fTerrain.Land[pY, pX].Height + FO + VO) / CELL_HEIGHT_DIV;
    y2 := pY - (fTerrain.Land[pY + 1, pX].Height + VO) / CELL_HEIGHT_DIV;

    FenceX := GFXData[rxGui,TexID].PxWidth / CELL_SIZE_PX;

    if Pos = dir_W then
    begin
      x1 := pX - 1 - 3 / CELL_SIZE_PX;
    end;
    if Pos = dir_E then
    begin
      x1 := pX - 1 - FenceX + 3 / CELL_SIZE_PX;

    end;

    glBegin(GL_QUADS);
      glTexCoord2f(UVa.x, UVa.y); glVertex2f(x1, y1);
      glTexCoord2f(UVb.x, UVa.y); glVertex2f(x1+ FenceX, y1);
      glTexCoord2f(UVb.x, UVb.y); glVertex2f(x1+ FenceX, y2);
      glTexCoord2f(UVa.x, UVb.y); glVertex2f(x1, y2);
    glEnd;
  end;
  glBindTexture(GL_TEXTURE_2D, 0);
end;


procedure TRenderTerrain.RenderMarkup(pX, pY: Word; aFieldType: TFieldType);
const
  MarkupTex: array [TFieldType] of Word = (0, 105, 107, 0, 108, 111);
var
  ID: Integer;
  UVa,UVb: TKMPointF;
begin
  ID := MarkupTex[aFieldType];

  glBindTexture(GL_TEXTURE_2D, GFXData[rxGui, ID].Tex.ID);

  UVa.X := GFXData[rxGui, ID].Tex.u1;
  UVa.Y := GFXData[rxGui, ID].Tex.v1;
  UVb.X := GFXData[rxGui, ID].Tex.u2;
  UVb.Y := GFXData[rxGui, ID].Tex.v2;

  glBegin(GL_QUADS);
    glTexCoord2f(UVb.x, UVa.y); glVertex2f(pX-1, pY-1 - fTerrain.Land[pY  ,pX  ].Height/CELL_HEIGHT_DIV+0.10);
    glTexCoord2f(UVa.x, UVa.y); glVertex2f(pX-1, pY-1 - fTerrain.Land[pY  ,pX  ].Height/CELL_HEIGHT_DIV-0.15);
    glTexCoord2f(UVa.x, UVb.y); glVertex2f(pX  , pY   - fTerrain.Land[pY+1,pX+1].Height/CELL_HEIGHT_DIV-0.25);
    glTexCoord2f(UVb.x, UVb.y); glVertex2f(pX  , pY   - fTerrain.Land[pY+1,pX+1].Height/CELL_HEIGHT_DIV);

    glTexCoord2f(UVb.x, UVa.y); glVertex2f(pX-1, pY   - fTerrain.Land[pY+1,pX  ].Height/CELL_HEIGHT_DIV);
    glTexCoord2f(UVa.x, UVa.y); glVertex2f(pX-1, pY   - fTerrain.Land[pY+1,pX  ].Height/CELL_HEIGHT_DIV-0.25);
    glTexCoord2f(UVa.x, UVb.y); glVertex2f(pX  , pY-1 - fTerrain.Land[pY  ,pX+1].Height/CELL_HEIGHT_DIV-0.15);
    glTexCoord2f(UVb.x, UVb.y); glVertex2f(pX  , pY-1 - fTerrain.Land[pY  ,pX+1].Height/CELL_HEIGHT_DIV+0.10);
  glEnd;

  glBindTexture(GL_TEXTURE_2D, 0);
end;


end.
