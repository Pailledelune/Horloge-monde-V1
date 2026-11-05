gl.setup(NATIVE_WIDTH, NATIVE_HEIGHT)

-- Polices Poppins (licence libre, voir OFL-poppins.txt)
local sans = resource.load_font "poppins.ttf"
local gras = resource.load_font "poppins-gras.ttf"

-- Carte du monde equirectangulaire (terres Natural Earth, domaine public)
local carte = resource.load_image{file = "carte.png", mipmap = true}

-- Couleurs
local FOND   = {0.027, 0.090, 0.165}
local TUILE  = {0.059, 0.153, 0.259}
local CLAIR  = {0.141, 0.322, 0.494}
local CREUX  = {0.027, 0.102, 0.184}
local BLANC  = {1.000, 1.000, 1.000}
local PALE   = {0.663, 0.757, 0.855}
local NUAGE  = {0.843, 0.886, 0.933}
local GRIS   = {0.561, 0.651, 0.745}
local ORAGE  = {0.478, 0.553, 0.639}
local OR     = {0.961, 0.722, 0.239}
local BLEU   = {0.435, 0.706, 0.941}
local GLACE  = {0.749, 0.902, 1.000}
local JAUNE  = {0.949, 0.831, 0.361}
local TEMP_ORANGE = {0.949, 0.604, 0.243}
local TEMP_ROUGE  = {0.898, 0.325, 0.239}

-- Couleur de la tuile sous le picto en cours : sert a mordre le croissant
local MORSURE = TUILE

-- Carte a l'ecran (rapport 2:1)
local MX, MY, MW, MH = 600, 25, 1280, 640

local blanc = resource.create_colored_texture(1, 1, 1, 1)

------------------------------------------------------------------------
-- Reglages et donnees
------------------------------------------------------------------------

local VIDE = "empty.png"
local logo, agence
local reference
local villes = {}

util.json_watch("config.json", function(c)
  if logo then logo:dispose() end
  logo = nil
  if type(c.logo) == "table" and type(c.logo.asset_name) == "string" and c.logo.asset_name ~= VIDE then
    logo = resource.load_image{file = c.logo.asset_name, mipmap = true}
  end
  agence = type(c.agence) == "string" and c.agence:match("^%s*(.-)%s*$") or ""
end)

util.json_watch("monde.json", function(m)
  reference = type(m.reference) == "table" and m.reference or nil
  villes = type(m.villes) == "table" and m.villes or {}
end)

------------------------------------------------------------------------
-- Shaders
------------------------------------------------------------------------

-- Rectangle a coins arrondis, disque ou trait a bouts ronds
local shader_forme = resource.create_shader[[
  #ifdef GL_ES
  precision mediump float;
  #endif
  uniform sampler2D Texture;
  varying vec2 TexCoord;
  uniform float w, h, rayon, r, g, b, alpha;
  void main() {
    vec2 q = abs((TexCoord - vec2(0.5)) * vec2(w, h)) - vec2(w, h) * 0.5 + rayon;
    float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rayon;
    float a = clamp(0.5 - d, 0.0, 1.0);
    gl_FragColor = texture2D(Texture, TexCoord) * vec4(r, g, b, a * alpha);
  }
]]

-- Carte assombrie la nuit, en trois paliers adoucis : coucher du soleil,
-- puis 3 et 6 degres sous l'horizon (crepuscule) ; coins arrondis
local shader_carte = resource.create_shader[[
  #ifdef GL_ES
  precision mediump float;
  #endif
  uniform sampler2D Texture;
  varying vec2 TexCoord;
  uniform float slon, sdecl, w, h, rayon;
  void main() {
    vec4 c = texture2D(Texture, TexCoord);
    float lon = radians(TexCoord.x * 360.0 - 180.0);
    float lat = radians(90.0 - TexCoord.y * 180.0);
    float d = radians(sdecl);
    float s = sin(lat) * sin(d) + cos(lat) * cos(d) * cos(lon - radians(slon));
    float alt = degrees(asin(clamp(s, -1.0, 1.0)));
    float n = 0.30 * (1.0 - smoothstep(-0.5, 0.5, alt))
            + 0.16 * (1.0 - smoothstep(-3.5, -2.5, alt))
            + 0.16 * (1.0 - smoothstep(-6.5, -5.5, alt));
    vec3 col = mix(c.rgb, vec3(0.008, 0.043, 0.094), n);
    vec2 q = abs((TexCoord - vec2(0.5)) * vec2(w, h)) - vec2(w, h) * 0.5 + rayon;
    float e = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rayon;
    gl_FragColor = vec4(col, clamp(0.5 - e, 0.0, 1.0));
  }
]]

------------------------------------------------------------------------
-- Outils de dessin
------------------------------------------------------------------------

local function forme(x, y, w, h, rayon, c, a)
  shader_forme:use{w = w, h = h, rayon = rayon, r = c[1], g = c[2], b = c[3], alpha = a or 1}
  blanc:draw(x, y, x + w, y + h)
  shader_forme:deactivate()
end

local function disque(x, y, r, c, a)
  forme(x - r, y - r, 2 * r, 2 * r, r, c, a)
end

local function trait(x1, y1, x2, y2, ep, c, a)
  local dx, dy = x2 - x1, y2 - y1
  gl.pushMatrix()
  gl.translate(x1, y1)
  gl.rotate(math.deg(math.atan2(dy, dx)), 0, 0, 1)
  forme(-ep / 2, -ep / 2, math.sqrt(dx * dx + dy * dy) + ep, ep, ep / 2, c, a)
  gl.popMatrix()
end

local function tuile(x, y, w, h, c)
  forme(x, y, w, h, 22, c or TUILE)
end

-- Texte pose sur sa ligne de base y ; ancre "g", "c" ou "d"
local function texte(f, t, x, y, taille, c, ancre)
  local w = f:width(t, taille)
  if ancre == "c" then x = x - w / 2 elseif ancre == "d" then x = x - w end
  f:write(x, y - taille * 0.85, t, taille, c[1], c[2], c[3], 1)
end

-- Reduit la taille pour que le texte tienne dans la largeur
local function ajuste(f, t, taille, largeur)
  local w = f:width(t, taille)
  if w > largeur then return taille * largeur / w end
  return taille
end

local function arrondi(v)
  return math.floor(v + 0.5)
end

local function couleur_temp(v)
  local n = arrondi(v or 0)
  if n <= 0 then return BLANC end
  if n <= 11 then return BLEU end
  if n <= 20 then return JAUNE end
  if n <= 30 then return TEMP_ORANGE end
  return TEMP_ROUGE
end

-- Temperature et son degre, dessine en anneau sur le fond de la tuile
local function temperature(v, x, y, taille, ancre, fond)
  local t = v and string.format("%d", arrondi(v)) or "--"
  local c = couleur_temp(v)
  local w = gras:width(t, taille)
  local e = taille * 0.30
  if ancre == "c" then x = x - (w + e) / 2 elseif ancre == "d" then x = x - w - e end
  gras:write(x, y - taille * 0.85, t, taille, c[1], c[2], c[3], 1)
  disque(x + w + e * 0.55, y - taille * 0.62, taille * 0.095, c)
  disque(x + w + e * 0.55, y - taille * 0.62, taille * 0.0475, fond)
end

------------------------------------------------------------------------
-- Animations de la meteo (dessinees sur environ +/- 100 unites)
------------------------------------------------------------------------

local function nuage(x, y, s, c)
  disque(x - s * 0.45, y + s * 0.10, s * 0.34, c)
  disque(x, y - s * 0.10, s * 0.46, c)
  disque(x + s * 0.45, y + s * 0.10, s * 0.34, c)
  forme(x - s * 0.45, y + s * 0.05, s * 0.90, s * 0.39, 0, c)
end

local function soleil(x, y, r, t)
  for i = 0, 9 do
    local a = t * 0.4 + i * math.pi / 5
    local l = r * (1.55 + 0.12 * math.sin(t * 2.4 + i))
    trait(x + math.cos(a) * r * 1.25, y + math.sin(a) * r * 1.25,
          x + math.cos(a) * l, y + math.sin(a) * l, r * 0.13, OR)
  end
  disque(x, y, r, OR)
end

-- Croissant : un disque clair mordu par un disque couleur de tuile
local function croissant(x, y, r)
  disque(x, y, r, NUAGE)
  disque(x + r * 0.42, y - r * 0.18, r * 0.86, MORSURE)
end

local function etoile(x, y, r, t, decalage)
  disque(x, y, r * (0.65 + 0.35 * math.sin(t * 2 + decalage)), OR)
end

local function flocon(x, y, r, a)
  for i = 0, 2 do
    local q = a + i * math.pi / 3
    trait(x - math.cos(q) * r, y - math.sin(q) * r,
          x + math.cos(q) * r, y + math.sin(q) * r, r * 0.28, BLANC)
  end
end

local ANIM = {}

function ANIM.soleil(t)
  soleil(0, 0, 50, t)
end

function ANIM.lune(t)
  croissant(-5, 0, 58)
  etoile(62, -55, 7, t, 0)
  etoile(78, 20, 5, t, 2)
  etoile(-75, -60, 5, t, 4)
  etoile(40, 70, 4, t, 1)
end

function ANIM.eclaircies(t)
  soleil(34, -30, 34, t)
  nuage(-14 + 10 * math.sin(t * 0.5), 26, 76, NUAGE)
end

function ANIM.eclaircies_nuit(t)
  croissant(36, -36, 38)
  etoile(-55, -60, 5, t, 1)
  etoile(85, 18, 4, t, 3)
  nuage(-14 + 10 * math.sin(t * 0.5), 26, 76, NUAGE)
end

function ANIM.nuageux(t)
  local o = math.sin(t * 0.5)
  nuage(-20 + 28 * o, -32, 54, GRIS)
  nuage(16 - 30 * o, 24, 72, NUAGE)
end

function ANIM.brouillard(t)
  for i = 0, 4 do
    local sens = (i % 2 == 0) and -1 or 1
    local o = sens * 26 * math.sin(t * 0.45 + i * 1.3)
    forme(-92 + o, -72 + i * 33, 184, 20, 10, NUAGE, 0.32 + 0.12 * i)
  end
end

function ANIM.pluie(t)
  nuage(0, -38, 70, NUAGE)
  for i = 0, 6 do
    local p = (t * 0.9 + i * 0.37) % 1
    local x = -66 + i * 22 - p * 12
    trait(x, 18 + p * 68, x - 5, 32 + p * 68, 6, BLEU)
  end
end

function ANIM.neige(t)
  nuage(0, -48, 66, NUAGE)
  for i = 0, 8 do
    local p = (t * 0.22 + i * 0.31) % 1
    local x = -88 + i * 22 + 9 * math.sin(t + i * 2)
    flocon(x, 6 + p * 92, 7 + (i % 3) * 2, t * ((i % 2 == 0) and 0.8 or -0.8))
  end
end

function ANIM.verglas(t)
  nuage(0, -48, 66, NUAGE)
  for i = 0, 4 do
    local x = -60 + i * 30
    local l = 26 + (i % 2) * 14 + 4 * math.sin(t * 2 + i)
    trait(x, 4, x, 4 + l, 6, GLACE)
    local q = (t * 0.4 + i * 0.2) % 1
    disque(x, 8 + l + q * 50, 3.5, GLACE, 1 - q)
  end
end

function ANIM.orage(t)
  local p = t % 3.2
  local eclair = p < 0.12 or (p > 0.22 and p < 0.32)
  nuage(0, -46, 70, ORAGE)
  local c = eclair and {1.0, 0.88, 0.54} or OR
  trait(10, 0, -18, 38, 13, c)
  trait(-18, 38, 16, 34, 13, c)
  trait(16, 34, -8, 84, 12, c)
end

local function animation(nom, x, y, s, t, fond)
  MORSURE = fond or TUILE
  local dessin = ANIM[nom] or ANIM.nuageux
  gl.pushMatrix()
  gl.translate(x, y)
  gl.scale(s, s, 1)
  dessin(t)
  gl.popMatrix()
  MORSURE = TUILE
end

------------------------------------------------------------------------
-- Heure, soleil et decalages
------------------------------------------------------------------------

local JOURS = {"Dimanche", "Lundi", "Mardi", "Mercredi", "Jeudi", "Vendredi", "Samedi"}
local MOIS = {"janvier", "février", "mars", "avril", "mai", "juin", "juillet",
              "août", "septembre", "octobre", "novembre", "décembre"}

local function jour_semaine(y, m, d)   -- 0 = dimanche
  local t = {0, 3, 2, 5, 0, 3, 5, 2, 6, 4, 2, 4}
  if m < 3 then y = y - 1 end
  return (y + math.floor(y / 4) - math.floor(y / 100) + math.floor(y / 400) + t[m] + d) % 7
end

-- Heure de Paris tant que le service n'a pas donne le fuseau de la reference
local function decalage_paris(utc)
  local debut = 3 * 10000 + (31 - jour_semaine(utc.year, 3, 31)) * 100 + 1
  local fin   = 10 * 10000 + (31 - jour_semaine(utc.year, 10, 31)) * 100 + 1
  local now   = utc.month * 10000 + utc.day * 100 + utc.hour
  if now >= debut and now < fin then return 7200 end
  return 3600
end

-- Point de la Terre ou le soleil est au zenith : longitude et declinaison,
-- avec l'equation du temps (precision de l'ordre du degre)
local function position_soleil(ts)
  local d = os.date("!*t", ts)
  local decl = -23.44 * math.cos(2 * math.pi / 365 * (d.yday + 10))
  local b = 2 * math.pi * (d.yday - 81) / 365
  local eot = 9.87 * math.sin(2 * b) - 7.53 * math.cos(b) - 1.5 * math.sin(b)
  local h = d.hour + d.min / 60 + d.sec / 3600
  local lon = (-15 * (h - 12 + eot / 60) + 540) % 360 - 180
  return lon, decl
end

-- Hauteur du soleil en degres au-dessus de l'horizon d'un lieu
local function hauteur_soleil(lat, lon, slon, decl)
  local r = math.pi / 180
  local s = math.sin(lat * r) * math.sin(decl * r)
          + math.cos(lat * r) * math.cos(decl * r) * math.cos((lon - slon) * r)
  return math.deg(math.asin(math.max(-1, math.min(1, s))))
end

local function texte_decalage(v)
  local e = ((v.decalage or 0) - ((reference and reference.decalage) or 0)) / 60
  if e == 0 then return "même heure" end
  local a = math.abs(e)
  local t = (e > 0 and "+" or "-") .. math.floor(a / 60) .. " h"
  if a % 60 ~= 0 then t = t .. string.format(" %02d", a % 60) end
  return t
end

local function projeter(lat, lon)
  return MX + (lon + 180) / 360 * MW, MY + (90 - lat) / 180 * MH
end

------------------------------------------------------------------------
-- Colonne de la ville de reference
------------------------------------------------------------------------

local function colonne_reference(d, t)
  tuile(40, 25, 540, 640, CLAIR)

  -- Logo, ou nom de l'agence a defaut
  if logo and logo:state() == "loaded" then
    local w, h = logo:size()
    local k = math.min(460 / w, 110 / h)
    logo:draw(310 - w * k / 2, 95 - h * k / 2, 310 + w * k / 2, 95 + h * k / 2)
  elseif agence ~= "" then
    texte(gras, agence, 310, 112, ajuste(gras, agence, 44, 460), BLANC, "c")
  end

  -- Heure : les deux points s'allument une seconde sur deux
  local h, m = string.format("%02d", d.hour), string.format("%02d", d.min)
  local taille = 150
  local wh, wp, wm = gras:width(h, taille), gras:width(":", taille), gras:width(m, taille)
  local x = 310 - (wh + wp + wm) / 2
  texte(gras, h, x, 300, taille, BLANC, "g")
  if d.sec % 2 == 0 then texte(gras, ":", x + wh, 300, taille, BLANC, "g") end
  texte(gras, m, x + wh + wp, 300, taille, BLANC, "g")

  local date = JOURS[d.wday] .. " " .. d.day .. " " .. MOIS[d.month] .. " " .. d.year
  texte(sans, date, 310, 352, ajuste(sans, date, 32, 480), PALE, "c")
  forme(80, 385, 460, 2, 1, {0.239, 0.416, 0.584})

  if not reference then
    texte(sans, "Connexion à la météo", 310, 520, 32, PALE, "c")
    return
  end
  local nom = reference.nom or ""
  texte(gras, nom, 310, 452, ajuste(gras, nom, 48, 480), OR, "c")
  if reference.erreur then
    texte(sans, reference.erreur, 310, 540, 32, PALE, "c")
    return
  end
  animation(reference.anim, 205, 545, 0.62, t, CLAIR)
  temperature(reference.temperature, 380, 580, 96, "c", CLAIR)
  local l = reference.libelle or ""
  texte(sans, l, 310, 638, ajuste(sans, l, 32, 480), PALE, "c")
end

------------------------------------------------------------------------
-- Carte du monde
------------------------------------------------------------------------

local function chevauche(a, b)
  return a[1] < b[3] and b[1] < a[3] and a[2] < b[4] and b[2] < a[4]
end

-- Etiquette a droite du point, sinon juste en dessous, au-dessus, a gauche,
-- puis en biais : la premiere place libre dans la carte, sans toucher ni une
-- autre etiquette ni le point d'une autre ville
local function placer_etiquette(x, y, w, h, prises)
  local essais = {
    {x + 16, y - h / 2}, {x - w / 2, y + 14}, {x - w / 2, y - 14 - h},
    {x - 16 - w, y - h / 2},
    {x + 8, y + 12}, {x - 8 - w, y + 12}, {x + 8, y - 12 - h}, {x - 8 - w, y - 12 - h},
  }
  local premier
  for _, e in ipairs(essais) do
    local r = {e[1], e[2], e[1] + w, e[2] + h}
    if r[1] >= MX + 8 and r[3] <= MX + MW - 8 and r[2] >= MY + 8 and r[4] <= MY + MH - 8 then
      premier = premier or r
      local libre = true
      for _, p in ipairs(prises) do
        if chevauche(r, p) then libre = false break end
      end
      if libre then return r end
    end
  end
  return premier or {x + 16, y - h / 2, x + 16 + w, y + h / 2}
end

local function dessiner_carte(ts, t, slon, decl)
  if carte:state() == "loaded" then
    shader_carte:use{slon = slon, sdecl = decl, w = MW, h = MH, rayon = 22}
    carte:draw(MX, MY, MX + MW, MY + MH)
    shader_carte:deactivate()
  else
    tuile(MX, MY, MW, MH)
  end

  -- Soleil au zenith
  local sx, sy = projeter(decl, slon)
  soleil(sx, sy, 15, t)

  -- Villes : point et etiquette "Nom HH:MM"
  local liste = {}
  if reference and reference.lat then liste[1] = reference end
  for _, v in ipairs(villes) do
    if v.lat then liste[#liste + 1] = v end
  end
  -- Les points de toutes les villes sont des obstacles pour les etiquettes
  local prises = {}
  for _, v in ipairs(liste) do
    local x, y = projeter(v.lat, v.lon)
    prises[#prises + 1] = {x - 13, y - 13, x + 13, y + 13}
  end
  for _, v in ipairs(liste) do
    local x, y = projeter(v.lat, v.lon)
    local ref = v == reference
    disque(x, y, ref and 11 or 9, CREUX)
    disque(x, y, ref and 8 or 6, ref and OR or BLANC)
    local l = os.date("!*t", ts + (v.decalage or 0))
    local e = (v.nom or "") .. "  " .. string.format("%02d:%02d", l.hour, l.min)
    local w = gras:width(e, 20) + 24
    local r = placer_etiquette(x, y, w, 34, prises)
    prises[#prises + 1] = r
    forme(r[1], r[2], w, 34, 17, CREUX, 0.9)
    texte(gras, e, r[1] + 12, r[2] + 24, 20, ref and OR or BLANC, "g")
  end
end

------------------------------------------------------------------------
-- Tuiles des villes du monde
------------------------------------------------------------------------

local function tuile_ville(v, x, y, w, h, ts, t, slon, decl)
  tuile(x, y, w, h)
  local cx = x + w / 2
  local nom = v.nom or ""
  texte(gras, nom, cx, y + 50, ajuste(gras, nom, 32, w - 24), OR, "c")
  if v.erreur then
    texte(sans, v.erreur, cx, y + 170, ajuste(sans, v.erreur, 26, w - 24), PALE, "c")
    return
  end
  local pays = v.pays or ""
  texte(sans, pays, cx, y + 82, ajuste(sans, pays, 20, w - 24), PALE, "c")

  local l = os.date("!*t", ts + (v.decalage or 0))
  local heure = string.format("%02d:%02d", l.hour, l.min)
  texte(gras, heure, cx, y + 168, ajuste(gras, heure, 68, w - 30), BLANC, "c")
  local nuit = v.lat and hauteur_soleil(v.lat, v.lon, slon, decl) < -0.83
  local etat = (nuit and "Nuit" or "Jour") .. "  ·  " .. texte_decalage(v)
  texte(sans, etat, cx, y + 206, ajuste(sans, etat, 22, w - 24), PALE, "c")

  animation(v.anim, x + w * 0.29, y + 270, 0.36, t)
  temperature(v.temperature, x + w - 26, y + 292, ajuste(gras, "-88", 54, w * 0.42), "d", TUILE)
  local lib = v.libelle or ""
  texte(sans, lib, cx, y + 345, ajuste(sans, lib, 26, w - 24), PALE, "c")
end

------------------------------------------------------------------------
-- Rendu
------------------------------------------------------------------------

function node.render()
  local t = sys.now()
  local ts = os.time()
  local utc = os.date("!*t", ts)
  local decalage = (reference and reference.decalage) or decalage_paris(utc)
  local d = os.date("!*t", ts + decalage)
  local slon, decl = position_soleil(ts)

  gl.clear(FOND[1], FOND[2], FOND[3], 1)

  -- Mise a l'echelle si l'ecran n'est pas en 1920 x 1080
  local k = math.min(WIDTH / 1920, HEIGHT / 1080)
  gl.translate((WIDTH - 1920 * k) / 2, (HEIGHT - 1080 * k) / 2)
  gl.scale(k, k, 1)

  colonne_reference(d, t)
  dessiner_carte(ts, t, slon, decl)

  local n = #villes
  if n == 0 then
    texte(sans, "Connexion à la météo", 960, 880, 36, PALE, "c")
    return
  end
  local w = (1840 - (n - 1) * 15) / n
  for i, v in ipairs(villes) do
    tuile_ville(v, 40 + (i - 1) * (w + 15), 690, w, 365, ts, t, slon, decl)
  end
end
