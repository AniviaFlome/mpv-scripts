# Subtitle Translate

mpv script that translates subtitles on screen. Hover a word for a dictionary popup, or show a translation panel.

## Dependencies

- `curl`
- `ffmpeg`

## Keys

| Key | Action |
| --- | --- |
| `Alt+t` | Cycle modes: off → hover dictionary → on-demand panel → always-on panel |
| `Ctrl+y` | Pin the mode 2 panel until the subtitle changes |

## Options

| Option | Default | Description |
| --- | --- | --- |
| `key_cycle_mode` | `Alt+t` | Mode cycle key |
| `key_show_translation` | `Ctrl+y` | Show translated text key (mode 2) |
| `mode_on_start` | `off` | `off` / `dict` / `ondemand` / `always` |
| `provider` | `mymemory` | `mymemory` / `google` / `lingva` / `libretranslate` / `deepl` |
| `word_provider` | `tureng` | `tureng` / `cambridge` / `wiktionary` / `reverso` |
| `lang_from` / `lang_to` | `en` / `tr` | Language pair |
| `position` | `top-center` | Panel anchor |
| `panel_font_scale` | `0.85` | Panel text size |
| `panel_padding` | `0.25` | Panel padding on all sides |
| `translation_background` | `no` | Panel background on/off |
| `hover_backend` | `replica` | Mode 1 display: `replica` / `native` / `mirror` |
| `hovered_color` | `ff5555` | Hovered word + popup header color |
| `replica_font_size` | `38` | Mode 1 line size |
| `replica_outline` | `3` | Mode 1 line outline width |
| `mirror_margin_y` | `56` | Mirror fallback line distance from bottom |
| `mirror_font_size` | `30` | Mirror fallback line size |
| `popup_font_size` | `32` | Dictionary popup text size |
| `popup_padding_x` / `popup_padding_y` | `0.35` / `0.12` | Popup padding |
| `dict_max_groups` / `dict_max_terms` | `4` / `6` | Limits dictionary groups and terms per group |
| `dict_max_lines` | `6` | Maximum popup lines per page; scroll to see the rest |
| `dict_url_template` | tureng URL | Browser URL for word clicks (`{word}` placeholder) |
| `prefetch` / `prefetch_all` | yes / yes | Translate the whole subtitle file at load |
| `prefetch_concurrency` | `4` | Parallel prefetch requests |
| `verbose` / `show_hitboxes` | no / no | Debugging |

Provider-specific: `deepl_api_key`, `deepl_free`, `libretranslate_url`, `libretranslate_api_key`, `lingva_instance`, `mymemory_email`.

## Example config

`~/.config/mpv/script-opts/subtitle-translate.conf`:

```ini
provider=mymemory
lang_from=en
lang_to=tr
word_provider=tureng

position=top-center
panel_font_scale=0.85
translation_background=no

popup_font_size=32
hovered_color=ff5555
prefetch_concurrency=4
```
