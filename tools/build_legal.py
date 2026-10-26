#!/usr/bin/env python3
"""Генерирует статические правовые страницы (рус + каз) для веб-приложения и лендинга.
Запуск: python3 tools/build_legal.py [папка_лендинга]
Тексты: tools/legal_ru.py, tools/legal_kk.py. Реквизиты — заменить [ЗАПОЛНИТЬ]/[ТОЛТЫРУ] в этих файлах и перезапустить."""
import os, sys, html
sys.path.insert(0, os.path.dirname(__file__))
import legal_ru, legal_kk

ORDER = ['privacy', 'terms', 'offer', 'reviews', 'cookies', 'contacts']
CSS = '''@import url("{fonts}");
:root{--p:#9a6b00;--bg:#F6F4EF;--s1:#fff;--t:#1a1a1a;--m:#5f5c56;--line:#e3ded3}
@media (prefers-color-scheme:dark){:root{--p:#E8B84B;--bg:#0F0F0F;--s1:#181818;--t:#f2f2f2;--m:#a7a7a7;--line:#2a2a2a}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--t);font:16px/1.65 Manrope,system-ui,sans-serif}
a{color:var(--p)}.wrap{max-width:860px;margin:0 auto;padding:16px}
header{display:flex;gap:10px;align-items:center;flex-wrap:wrap;padding:12px 16px;border-bottom:1px solid var(--line);background:var(--s1);position:sticky;top:0}
.logo{font-weight:800;letter-spacing:.5px;color:var(--t);text-decoration:none;margin-right:auto}.logo b{color:var(--p)}
.lang{padding:6px 12px;border:1px solid var(--line);border-radius:999px;text-decoration:none;font-weight:700}
nav.docs{display:flex;gap:6px;flex-wrap:wrap;margin:14px 0}nav.docs a{padding:6px 11px;border-radius:999px;background:var(--s1);border:1px solid var(--line);text-decoration:none;font-size:14px;color:var(--t)}nav.docs a[aria-current]{border-color:var(--p);color:var(--p);font-weight:700}
article{background:var(--s1);border:1px solid var(--line);border-radius:16px;padding:18px 20px}
h1{font-size:26px;line-height:1.2;margin:.2em 0}h2{font-size:19px;margin:1.4em 0 .4em}.ver{color:var(--m);font-size:14px}
.lead{font-size:17px;padding:12px 14px;border-left:4px solid var(--p);background:color-mix(in srgb,var(--p) 8%,transparent);border-radius:8px}
.summary{border:1px solid var(--p);border-radius:12px;padding:4px 16px;margin:12px 0}
table{border-collapse:collapse;width:100%;margin:10px 0;font-size:15px}td,th{border:1px solid var(--line);padding:7px 9px;text-align:left;vertical-align:top}th{background:color-mix(in srgb,var(--p) 10%,transparent)}
mark.fill{background:#ffe08a;color:#3a2c00;padding:0 3px;border-radius:4px}
.mono{font-family:'JetBrains Mono',monospace;font-size:13px}.muted{color:var(--m)}.small{font-size:14px}
.btn{display:inline-block;padding:10px 16px;border-radius:12px;background:var(--p);color:#111!important;font-weight:800;text-decoration:none}
footer{color:var(--m);font-size:14px;padding:20px 16px 40px;max-width:860px;margin:0 auto}footer a{margin-right:12px;display:inline-block}
.note{background:#fff3d1;color:#5a4300;border-radius:10px;padding:8px 12px;font-size:14px}
:focus-visible{outline:3px solid var(--p);outline-offset:2px}.skip{position:absolute;left:-999px}.skip:focus{left:8px;top:8px;background:var(--p);color:#111;padding:6px 10px;z-index:9}
@media print{header,nav.docs,footer{display:none}article{border:0}}'''

def page(mod, key, lang, app, other_href, fonts):
    title, body = mod.DOCS[key]
    body = body.replace('../#/', app + '#/')
    nav = ''.join(f'<a href="{k}.html"{" aria-current=\"page\"" if k == key else ""}>{html.escape(mod.NAMES[k])}</a>' for k in ORDER)
    note = f'<p class="note">{mod.UI["nolegal"]}</p>' if ('ЗАПОЛНИТЬ' in body or 'ТОЛТЫРУ' in body) else ''
    return f'''<!doctype html>
<html lang="{lang}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{html.escape(title)} — АвтоМастер24</title><meta name="robots" content="index,follow">
<meta name="description" content="{html.escape(title)} сервиса АвтоМастер24 (Казахстан).">
<link rel="icon" href="{fonts.rsplit('assets/', 1)[0]}assets/favicon.svg" type="image/svg+xml">
<link rel="alternate" hreflang="{'kk' if lang == 'ru' else 'ru'}" href="{other_href}">
<style>{CSS.replace('{fonts}', fonts)}</style></head>
<body><a class="skip" href="#doc">{mod.UI['skip']}</a>
<header><a class="logo" href="{app}">АВТОМАСТЕР<b>24</b></a><a class="lang" href="{other_href}" lang="{'kk' if lang == 'ru' else 'ru'}">{mod.UI['other']}</a><a href="{app}">{mod.UI['back']}</a></header>
<div class="wrap"><nav class="docs" aria-label="{mod.UI['docs']}">{nav}</nav>
<article id="doc"><h1>{html.escape(title)}</h1><p class="ver">{mod.UI['ver']}</p>{note}{body}</article></div>
<footer><p>{mod.UI['disc']}</p><p>{nav.replace(' aria-current="page"', '')}</p><p>© 2026 АвтоМастер24 · 18+</p></footer>
</body></html>
'''

def build(out, app_ru, app_kk, fonts_ru, fonts_kk):
    os.makedirs(os.path.join(out, 'kk'), exist_ok=True)
    for k in ORDER:
        open(os.path.join(out, f'{k}.html'), 'w').write(page(legal_ru, k, 'ru', app_ru, f'kk/{k}.html', fonts_ru))
        open(os.path.join(out, 'kk', f'{k}.html'), 'w').write(page(legal_kk, k, 'kk', app_kk, f'../{k}.html', fonts_kk))
    print('OK', out)

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
build(os.path.join(root, 'site', 'legal'), '../', '../../?lang=kk', '../assets/fonts/fonts.css', '../../assets/fonts/fonts.css')
if len(sys.argv) > 1:  # лендинг: ссылки ведут в веб-приложение
    APP = 'https://avtomaster24bot-lab.github.io/avtomaster24-web/'
    build(os.path.join(sys.argv[1], 'legal'), APP, APP + '?lang=kk', APP + 'assets/fonts/fonts.css', APP + 'assets/fonts/fonts.css')
