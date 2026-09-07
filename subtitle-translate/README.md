# Subtitle Translate

mpv script that translates subtitles on screen. Hover a word for a dictionary popup, or show a translation panel.

## Dependencies

- `curl`, `ffmpeg`
- `tesseract`, `rapidocr-onnxruntime`, `easyocr`, `paddleocr` (optional)

## Keys

| Key | Action |
| --- | --- |
| `Alt+t` | Cycle modes: off → hover dictionary → on-demand panel → always-on panel |
| `Alt+y` | OCR current frame (hardsubs); press again to hide |
| `Ctrl+y` | Pin the mode 2 panel until the subtitle changes |
| `Alt+T` | Session-only settings menu |
| `Alt+d` | Dictionary search |
| `Alt+D` | Free-text translation |

## Options

`~/.config/mpv/script-opts/subtitle-translate.conf`

Keys

| Option | Default | Description |
| --- | --- | --- |
| `key_cycle_mode` | `Alt+t` | |
| `key_dict_box` | `Alt+d` | |
| `key_ocr` | `Alt+y` | |
| `key_settings_menu` | `Alt+T` | |
| `key_show_translation` | `Ctrl+y` | |
| `key_translate_box` | `Alt+D` | |

Translation

| Option | Default | Description |
| --- | --- | --- |
| `lang_from` | `en` | |
| `lang_to` | `tr` | |
| `mode_on_start` | `off` | `off` / `dict` / `ondemand` / `always` |
| `provider` | `mymemory` | `mymemory` / `google` / `duckduckgo` / `lingva` / `libretranslate` / `deepl` / `yandex` |
| `word_provider` | `cambridge` | `tureng` / `cambridge` / `wiktionary` / `reverso` |

Panel

| Option | Default | Description |
| --- | --- | --- |
| `bg_opacity` | `55` | |
| `color_bg` | `#101010` | |
| `color_outline` | `#101010` | |
| `color_text` | `#ffffff` | |
| `font` | `sans-serif` | |
| `margin_y` | `24` | |
| `max_width_percent` | `80` | |
| `outline_width` | `1` | |
| `panel_font_scale` | `0.85` | |
| `position` | `top-center` | |

Hover dictionary

| Option | Default | Description |
| --- | --- | --- |
| `accent` | `#ff5555` | |
| `color_mirror` | `#ffffff` | |
| `hover_backend` | `replica` | `replica` / `native` / `mirror` |
| `mirror_font` | `monospace` | |
| `mirror_font_size` | `30` | |
| `mirror_margin_y` | `56` | |
| `replica_font_size` | `38` | |
| `replica_outline` | `3` | |

Dictionary popup

| Option | Default | Description |
| --- | --- | --- |
| `dict_max_groups` | `4` | |
| `dict_max_lines` | `6` | |
| `dict_max_terms` | `6` | |
| `dict_url_template` | tureng URL | `{word}` placeholder |
| `popup_font_size` | `32` | |
| `popup_offset` | `18` | |
| `popup_padding_x` | `0.35` | |
| `popup_padding_y` | `0.12` | |

Prefetch and cache

| Option | Default | Description |
| --- | --- | --- |
| `cache_dir` | _(empty)_ | |
| `cache_max_entries` | `5000` | |
| `disk_cache` | yes | |
| `prefetch` | yes | |
| `prefetch_all` | no | |
| `prefetch_ahead` | `20` | |
| `prefetch_concurrency` | `2` | |

Debugging

| Option | Default | Description |
| --- | --- | --- |
| `show_hitboxes` | no | |
| `verbose` | no | |

DeepL

| Option | Default | Description |
| --- | --- | --- |
| `deepl_api_key` | _(empty)_ | Pro API key (`:fx` suffix = free tier) |

LibreTranslate

| Option | Default | Description |
| --- | --- | --- |
| `libretranslate_url` | `https://libretranslate.com` | Self-hosted instance |
| `libretranslate_api_key` | _(empty)_ | If the instance needs one |

Lingva

| Option | Default | Description |
| --- | --- | --- |
| `lingva_instance` | `https://lingva.ml` | Instance URL |

MyMemory

| Option | Default | Description |
| --- | --- | --- |
| `mymemory_email` | _(empty)_ | Raises anonymous quota |

Yandex

| Option | Default | Description |
| --- | --- | --- |
| `yandex_api_key` | _(empty)_ | Service-account API key |
| `yandex_folder_id` | _(empty)_ | Folder ID |

`mymemory` (without email), `google` and `duckduckgo` need no credentials.

## OCR

`Alt+y` captures a frame, recognizes it, translates, and shows the panel.

General

| Option | Default | Description |
| --- | --- | --- |
| `ocr_enabled` | `yes` | |
| `ocr_backend` | `tesseract` | `tesseract` / `custom` / `rapidocr` / `easyocr` / `paddleocr` / `baiduocr` |
| `ocr_crop_h` | `0.25` | |
| `ocr_scale` | `2` | |
| `ocr_sharpen` | yes | |
| `ocr_lang` | _(empty)_ | Overrides `lang_from` for OCR |
| `ocr_min_chars` | `2` | Drop shorter reads |
| `ocr_max_chars` | `200` | Drop longer reads |
| `ocr_min_alpha_ratio` | `0.5` | Drop symbol soup (`0` disables) |
| `ocr_display_seconds` | `5` | Auto-hide panel |

Tesseract only

| Option | Default | Description |
| --- | --- | --- |
| `ocr_psm` | `6` | Segmentation mode |
| `ocr_oem` | `1` | LSTM only |
| `ocr_tessconfig` | _(empty)_ | Extra `-c key=value` opts |
| `ocr_blacklist` | <code>|\@#¥§©®™°^~\</code> | Chars tesseract never emits |

Python backends (`rapidocr` / `easyocr` / `paddleocr`)

| Option | Default | Description |
| --- | --- | --- |
| `ocr_cuda` | `no` | `easyocr` CUDA |

Custom backend

| Option | Default | Description |
| --- | --- | --- |
| `ocr_command` | _(empty)_ | CLI (`{image}`, `{lang}` placeholders) |

Baidu OCR (cloud account needed)

| Option | Default | Description |
| --- | --- | --- |
| `baiduocr_api_key` | _(empty)_ | App API Key |
| `baiduocr_secret_key` | _(empty)_ | App Secret Key |

## Example config

```ini
provider=mymemory
lang_from=en
lang_to=tr
word_provider=cambridge

position=top-center
panel_font_scale=0.85

popup_font_size=32
accent=#cba6f7
prefetch_concurrency=2

ocr_backend=tesseract
```
