# Map a matugen palette onto Omarchy's colors.toml.
#
# Input:  `matugen image <path> --json hex --mode <mode>` on stdin.
# Args:   $mode = "dark" | "light"
# Output: the 26 keys every Omarchy theme declares, as TOML.
#
# The two halves of the file do quite different jobs.
#
# The structural roles (backgrounds, foregrounds, accent, selection, muted) come
# straight from matugen. Material You's surface tiers are already an ordered
# ramp with contrast guarantees, which is exactly the shape Omarchy wants.
#
# The eight ANSI hues cannot come from matugen. Material You harmonises a scheme
# around a single seed hue, so its base16 output is a monochrome ramp -- every
# "color" a different lightness of the same orange. A terminal needs red to be
# red and green to be green. So those are synthesised here: each starts at its
# canonical hue, is nudged toward the image's hue (the same harmonisation
# Material applies to custom colors, 15% of the difference capped at 15 degrees)
# and is rendered at a saturation borrowed from the image. The result reads as
# red while still belonging to the wallpaper it came from.

def clampv($lo; $hi): if . < $lo then $lo elif . > $hi then $hi else . end;

def hexdigit:
  {"0":0,"1":1,"2":2,"3":3,"4":4,"5":5,"6":6,"7":7,"8":8,"9":9,
   "a":10,"b":11,"c":12,"d":13,"e":14,"f":15}[.] // 0;

def hexpair: (.[0:1] | ascii_downcase | hexdigit) * 16
           + (.[1:2] | ascii_downcase | hexdigit);

def hex2rgb:
  (ltrimstr("#")) as $h
  | [($h[0:2] | hexpair), ($h[2:4] | hexpair), ($h[4:6] | hexpair)];

def tohex2:
  (. | floor | clampv(0; 255)) as $v
  | ("0123456789abcdef" | .[($v / 16 | floor):($v / 16 | floor) + 1])
  + ("0123456789abcdef" | .[($v % 16):($v % 16) + 1]);

def rgb2hex: "#" + (.[0] | tohex2) + (.[1] | tohex2) + (.[2] | tohex2);

def fmod($a; $b): $a - ($b * (($a / $b) | floor));

# [r,g,b] 0-255 -> [h 0-360, s 0-1, l 0-1]
def rgb2hsl:
  (.[0] / 255) as $r | (.[1] / 255) as $g | (.[2] / 255) as $b
  | ([$r, $g, $b] | max) as $mx
  | ([$r, $g, $b] | min) as $mn
  | ($mx - $mn) as $d
  | (($mx + $mn) / 2) as $l
  | (if $d == 0 then 0
     elif $mx == $r then fmod(60 * (($g - $b) / $d); 360)
     elif $mx == $g then 60 * (($b - $r) / $d) + 120
     else 60 * (($r - $g) / $d) + 240 end) as $h0
  | (if $d == 0 then 0
     elif $l > 0.5 then $d / (2 - $mx - $mn)
     else $d / ($mx + $mn) end) as $s
  | [(if $h0 < 0 then $h0 + 360 else $h0 end), $s, $l];

# [h,s,l] -> "#rrggbb"
def hsl2hex:
  (fmod(.[0]; 360)) as $h
  | (.[1] | clampv(0; 1)) as $s
  | (.[2] | clampv(0; 1)) as $l
  | ((1 - ((2 * $l - 1) | fabs)) * $s) as $c
  | ($h / 60) as $hp
  | ($c * (1 - ((fmod($hp; 2) - 1) | fabs))) as $x
  | ($l - $c / 2) as $m
  | (if $hp < 1 then [$c, $x, 0]
     elif $hp < 2 then [$x, $c, 0]
     elif $hp < 3 then [0, $c, $x]
     elif $hp < 4 then [0, $x, $c]
     elif $hp < 5 then [$x, 0, $c]
     else [$c, 0, $x] end)
  | [(.[0] + $m) * 255, (.[1] + $m) * 255, (.[2] + $m) * 255]
  | rgb2hex;

def role($name): .colors[$name][$mode].color;

# Nudge $hue toward $target the way Material harmonises a custom color against
# a scheme: take a fraction of the shortest angular difference, capped, so a
# red stays red but picks up the image's warmth.
def harmonize($hue; $target; $fraction; $cap):
  (fmod($target - $hue + 540; 360) - 180) as $diff
  | ($diff * $fraction) as $shift
  | (if $shift > $cap then $cap elif $shift < -$cap then -$cap else $shift end)
  | fmod($hue + . + 360; 360);

(role("source_color") | hex2rgb | rgb2hsl) as $src
| $src[0] as $srchue
# Saturation follows the image but is held inside a band: an almost-grey
# wallpaper would otherwise yield ANSI colors too washed out to tell apart,
# and a neon one would yield colors that vibrate against the background.
| (($src[1] * 0.9 + 0.15) | clampv(0.42; 0.78)) as $sat
| ($mode == "dark") as $dark
| (if $dark then 0.70 else 0.42 end) as $lit
# The bright variants sit only a little above the base ones. Pushing them
# further turns them into pastels that read as washed out rather than bright,
# which is why the stock themes keep the two within a few percent.
| (if $dark then 0.77 else 0.34 end) as $britelit
| (if $dark then 1.08 else 1.12 end) as $britesat

# hue, saturation multiplier, lightness multiplier
| {
    red:     [ 2, 1.00, 1.00],
    orange:  [28, 1.00, 1.02],
    yellow:  [48, 1.00, 1.05],
    green:   [122, 0.92, 1.00],
    cyan:    [186, 0.95, 0.98],
    blue:    [218, 1.00, 0.98],
    magenta: [292, 0.95, 1.00],
    brown:   [22, 0.55, 0.62]
  } as $hues

| def ansi($name; $bright):
    $hues[$name] as $spec
    | [ harmonize($spec[0]; $srchue; 0.15; 15),
        (($sat * $spec[1] * (if $bright then $britesat else 1 end)) | clampv(0; 1)),
        (((if $bright then $britelit else $lit end) * $spec[2]) | clampv(0.05; 0.95)) ]
    | hsl2hex;

  [
    "mode = \"" + $mode + "\"",
    "",
    "accent = \"" + role("primary") + "\"",
    "selection = \"" + role("surface_container_highest") + "\"",
    "muted = \"" + role("outline_variant") + "\"",
    "",
    # Both ramps run literally, not semantically: in a light theme
    # dark_background really is darker than background, and foreground really
    # is the near-black text color. The stock light themes (catppuccin-latte,
    # flexoki-light) are read the same way, so the surface tiers have to be
    # picked in the opposite order per mode rather than reused.
    "background = \"" + role("surface") + "\"",
    "dark_background = \"" + (if $dark then role("surface_container_lowest")
                              else role("surface_container") end) + "\"",
    "darker_background = \"" + (if $dark then
       # Nothing sits below surface_container_lowest, so the darkest tier is
       # derived rather than looked up.
       (role("surface_container_lowest") | hex2rgb | rgb2hsl
         | [.[0], .[1], .[2] * 0.55] | hsl2hex)
     else role("surface_container_highest") end) + "\"",
    "lighter_background = \"" + (if $dark then role("surface_container_high")
                                 else role("surface_container_low") end) + "\"",
    "",
    "foreground = \"" + (if $dark then role("on_surface_variant")
                         else role("on_surface") end) + "\"",
    "dark_foreground = \"" + role("outline") + "\"",
    "light_foreground = \"" + (if $dark then role("on_surface")
                               else role("on_surface_variant") end) + "\"",
    "bright_foreground = \"" + (if $dark then
       (role("on_surface") | hex2rgb | rgb2hsl | [.[0], .[1], .[2] * 1.06] | hsl2hex)
     else role("on_surface") end) + "\"",
    "",
    "red = \"" + ansi("red"; false) + "\"",
    "yellow = \"" + ansi("yellow"; false) + "\"",
    "orange = \"" + ansi("orange"; false) + "\"",
    "green = \"" + ansi("green"; false) + "\"",
    "cyan = \"" + ansi("cyan"; false) + "\"",
    "blue = \"" + ansi("blue"; false) + "\"",
    "magenta = \"" + ansi("magenta"; false) + "\"",
    "brown = \"" + ansi("brown"; false) + "\"",
    "",
    "bright_red = \"" + ansi("red"; true) + "\"",
    "bright_yellow = \"" + ansi("yellow"; true) + "\"",
    "bright_green = \"" + ansi("green"; true) + "\"",
    "bright_cyan = \"" + ansi("cyan"; true) + "\"",
    "bright_blue = \"" + ansi("blue"; true) + "\"",
    "bright_magenta = \"" + ansi("magenta"; true) + "\""
  ] | join("\n")
