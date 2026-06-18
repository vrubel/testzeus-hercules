#!/usr/bin/env bash
# Сборка этого (урезанного) форка TestZeus Hercules в изолированный Python-venv (Linux/macOS).
#
# Назначение. Вы склонировали этот репозиторий на хост, где УЖЕ ЕСТЬ Python (>=3.11,<3.14). Скрипт
# делает всё остальное сам: создаёт venv и ставит в него ТОЛЬКО Python-пакеты, доказывая, что во
# время сборки НЕ скачивается ни одного НЕ-python артефакта (браузер Playwright, ONNX-модель
# chromadb, веса HuggingFace — это рантайм-докачки, и здесь они явно заблокированы).
#
# Чего скрипт НЕ делает (намеренно):
#   • не качает браузер (`playwright install`) и не ставит системные libs (`install-deps`, root);
#   • не тянет модели/веса (offline-флаги выставлены на время сборки);
#   • не трогает систему вне venv (никаких apt/brew/uv/sudo).
# Это самодостаточная альтернатива `make install` (тот требует uv и качает браузер с системными libs).
#
# Любое отклонение — ГРОМКАЯ остановка с подробной диагностикой.
#
# Использование (из корня клонированного репозитория):
#   ./build.sh                         # собрать этот репозиторий в ./.venv
#   HERCULES_VENV=/path/to/venv ./build.sh
#   ./build.sh /path/to/another/checkout
#   ./build.sh --help
#
# Переменные окружения:
#   HERCULES_VENV   — куда положить venv (по умолчанию: <репозиторий>/.venv).
#   PYTHON          — какой интерпретатор-донор использовать (по умолчанию: python3).
#   PIP_INDEX_URL   — уважается как обычно (миррор/корп-реестр подхватятся автоматически).

set -euo pipefail

step()  { printf '\n\033[1m→ %s\033[0m\n' "$*"; }
info()  { printf '  ⓘ %s\n' "$*"; }
ok()    { printf '\033[32mok: %s\033[0m\n' "$*"; }
warn()  { printf '\033[33m⚠ %s\033[0m\n' "$*" >&2; }
fail()  { printf '\n\033[31mFAIL: %s\033[0m\n' "$*" >&2; diagnostics; exit 1; }

diagnostics() {
  printf '\n\033[1m── ДИАГНОСТИКА ─────────────────────────────────────────\033[0m\n' >&2
  printf '  ОС/арх:        %s %s\n' "$(uname -s 2>/dev/null || echo '?')" "$(uname -m 2>/dev/null || echo '?')" >&2
  printf '  репозиторий:   %s\n' "${REPO:-<не определён>}" >&2
  printf '  venv:          %s\n' "${VENV:-<не создан>}" >&2
  printf '  донор-python:  %s\n' "${PYBIN:-<не найден>}" >&2
  if [ -n "${VPY:-}" ] && [ -x "$VPY" ]; then
    printf '  venv-python:   %s (%s)\n' "$VPY" "$("$VPY" -V 2>&1 || true)" >&2
    printf '  venv-pip:      %s\n' "$("$VPY" -m pip --version 2>&1 || echo '?')" >&2
  fi
  if [ -n "${PIP_LOG:-}" ] && [ -f "$PIP_LOG" ]; then
    printf '  --- последние 40 строк лога pip (%s) ---\n' "$PIP_LOG" >&2
    tail -n 40 "$PIP_LOG" >&2 || true
  fi
  printf '\033[1m────────────────────────────────────────────────────────\033[0m\n' >&2
}

# Каталог скрипта = по умолчанию репозиторий, который собираем (работает из любого cwd).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO_ARG=""
for a in "$@"; do
  case "$a" in
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) fail "неизвестный флаг: $a (см. --help)" ;;
    *)  [ -z "$REPO_ARG" ] || fail "лишний аргумент: $a (ожидается один путь к клону)"
        REPO_ARG="$a" ;;
  esac
done

PYBIN="${PYTHON:-python3}"
VPY=""; PIP_LOG=""

case "$(uname -s)" in
  Darwin) PW_CACHE="$HOME/Library/Caches/ms-playwright" ;;
  *)      PW_CACHE="${PLAYWRIGHT_BROWSERS_PATH:-$HOME/.cache/ms-playwright}" ;;
esac
HF_CACHE="${HF_HOME:-$HOME/.cache/huggingface}"
PW_PRE=0; [ -e "$PW_CACHE" ] && PW_PRE=1
HF_PRE=0; [ -e "$HF_CACHE" ] && HF_PRE=1

# ── 1. дерево репозитория ─────────────────────────────────────────────────────────────────────
step "Проверка дерева репозитория"
REPO="$(cd "${REPO_ARG:-$SCRIPT_DIR}" 2>/dev/null && pwd)" || fail "каталог не найден: ${REPO_ARG:-$SCRIPT_DIR}"
[ -f "$REPO/pyproject.toml" ] || fail "в '$REPO' нет pyproject.toml — это не дерево Hercules"
grep -q 'name *= *"testzeus-hercules"' "$REPO/pyproject.toml" \
  || fail "pyproject.toml в '$REPO' не про testzeus-hercules — указан не тот каталог"
VENV="${HERCULES_VENV:-$REPO/.venv}"
ok "репозиторий: $REPO"
info "версия пакета: $(grep -m1 '^version' "$REPO/pyproject.toml" | sed 's/.*= *//; s/\"//g')"

# ── 2. интерпретатор-донор ──────────────────────────────────────────────────────────────────────
step "Проверка Python на хосте (нужен >=3.11,<3.14)"
command -v "$PYBIN" >/dev/null 2>&1 || fail "интерпретатор '$PYBIN' не найден на PATH (задайте PYTHON=...). Поставьте Python 3.11–3.13."
"$PYBIN" - <<'PYEOF' || fail "версия Python не подходит (нужен >=3.11 и <3.14). Установите подходящую и/или задайте PYTHON=/путь/к/python."
import sys
v = sys.version_info
print(f"  ⓘ донор: {sys.executable}  ({sys.version.split()[0]})")
sys.exit(0 if (3, 11) <= (v.major, v.minor) < (3, 14) else 1)
PYEOF
ok "Python-донор пригоден"

# ── 3. чистый venv ──────────────────────────────────────────────────────────────────────────
step "Создание изолированного venv: $VENV"
if [ -e "$VENV" ]; then warn "venv уже существует — пересоздаю с нуля"; rm -rf "$VENV"; fi
mkdir -p "$(dirname "$VENV")"
"$PYBIN" -m venv "$VENV" || fail "не удалось создать venv в $VENV (нет модуля venv? на Debian/Ubuntu: пакет python3-venv)"
VPY="$VENV/bin/python"
[ -x "$VPY" ] || fail "venv создан, но в нём нет python ($VPY)"
ok "venv готов: $VPY ($("$VPY" -V 2>&1))"

step "Обновление pip/setuptools/wheel в venv"
"$VPY" -m pip install --quiet --upgrade pip setuptools wheel \
  || fail "не удалось обновить pip/setuptools/wheel (проблема сети/индекса? проверьте PIP_INDEX_URL)"
ok "$("$VPY" -m pip --version)"

# ── 4. GUARD'ы против докачки НЕ-python артефактов ─────────────────────────────────────────────
step "Блокировка любых докачек бинарей/моделей на время сборки"
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export HF_HUB_DISABLE_TELEMETRY=1
export PIP_NO_INPUT=1
export PIP_DISABLE_PIP_VERSION_CHECK=1
info "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1, HF_HUB_OFFLINE=1, TRANSFORMERS_OFFLINE=1 (+ telemetry off)"

# ── 5. сухой прогон: доказательство «только python» ───────────────────────────────────────────
step "Сухой прогон: резолв зависимостей и проверка, что ВСЁ — python-дистрибутивы"
REPORT="$(mktemp -t hercules-report.XXXXXX.json)"
PIP_LOG="$(mktemp -t hercules-pip.XXXXXX.log)"
if ! "$VPY" -m pip install --dry-run --report "$REPORT" --prefer-binary "$REPO" >"$PIP_LOG" 2>&1; then
  cat "$PIP_LOG" >&2
  fail "резолв зависимостей не прошёл (см. лог pip выше). Частые причины: недоступен индекс/миррор; пакета нет под эту версию Python/ОС."
fi
"$VPY" - "$REPORT" <<'PYEOF' || fail "в плане установки обнаружен НЕ python-дистрибутив (детали выше) — сборка остановлена"
import json, sys, os
# encoding явно UTF-8: на Windows дефолт — cp1252, а JSON-отчёт pip содержит не-cp1252 байты.
rep = json.load(open(sys.argv[1], encoding="utf-8"))
items = rep.get("install", [])
PYEXT = (".whl", ".tar.gz", ".tgz", ".zip", ".tar.bz2")
bad, rows = [], []
for it in items:
    meta = it.get("metadata", {})
    name = meta.get("name", "?"); ver = meta.get("version", "?")
    di = it.get("download_info", {}) or {}
    url = di.get("url", ""); low = url.lower()
    if di.get("dir_info") is not None or low.startswith("file://"):
        kind = "local-tree"
    elif di.get("vcs_info") is not None:
        kind = "vcs"
    elif low.endswith(PYEXT):
        kind = "wheel" if low.endswith(".whl") else "sdist"
    else:
        kind = "ПОДОЗРИТЕЛЬНО"; bad.append((name, ver, url))
    fname = os.path.basename(url.split("?")[0]) or url
    rows.append((name, ver, kind, fname))
w = max((len(r[0]) for r in rows), default=4)
print(f"  пакетов к установке: {len(rows)} (источник — индекс pip / локальное дерево)")
for name, ver, kind, fname in sorted(rows):
    flag = "  " if kind != "ПОДОЗРИТЕЛЬНО" else ">>"
    print(f"  {flag} {name:<{w}}  {ver:<14} [{kind}] {fname}")
if bad:
    print("\n  НЕ python-дистрибутивы (запрещённые бинарники):", file=sys.stderr)
    for name, ver, url in bad:
        print(f"    {name} {ver}: {url}", file=sys.stderr)
    sys.exit(1)
print("  ✓ каждый источник — python-дистрибутив (wheel/sdist), локальное дерево или VCS; посторонних бинарей нет")
PYEOF
ok "состав установки проверен — только python-пакеты"

# ── 6. установка ───────────────────────────────────────────────────────────────────────────────
step "Установка в venv (только python-пакеты, --prefer-binary)"
if ! "$VPY" -m pip install --prefer-binary "$REPO" >"$PIP_LOG" 2>&1; then
  tail -n 60 "$PIP_LOG" >&2
  fail "установка не прошла (см. лог pip выше: $PIP_LOG)"
fi
BUILT="$(grep -Eo 'Building wheel for [^ ]+' "$PIP_LOG" | sed 's/Building wheel for //' | sort -u || true)"
[ -n "$BUILT" ] && info "собрано из исходников (sdist, python): $(echo "$BUILT" | tr '\n' ' ')" || info "всё поставлено готовыми wheel'ами"
ok "пакеты установлены"

# ── 7. аудит: НЕ-python бинари НЕ появились ─────────────────────────────────────────────────────
step "Аудит: проверка, что сборка не притащила браузер/модели/веса"
audit_fail=0
HBIN="$VENV/bin/testzeus-hercules"
[ -x "$HBIN" ] || { warn "не найден entrypoint $HBIN — пакет установился без console-script?"; audit_fail=1; }
# find_spec НЕ исполняет тяжёлый __init__ пакета (он грузит движок и в интерактиве спрашивает email),
# поэтому импортируемость проверяем именно так — чисто и без побочных эффектов.
if "$VPY" -c 'import importlib.util,sys; sys.exit(0 if importlib.util.find_spec("testzeus_hercules") else 1)' 2>/dev/null; then
  ok "пакет testzeus_hercules установлен и импортируем (find_spec); entrypoint на месте"
else
  warn "пакет testzeus_hercules не виден интерпретатору venv — установка неполна"; audit_fail=1
fi
if [ "$PW_PRE" = "0" ] && [ -e "$PW_CACHE" ]; then
  warn "сборка СОЗДАЛА кэш браузеров Playwright: $PW_CACHE — этого быть не должно"; ls -la "$PW_CACHE" >&2 || true; audit_fail=1
elif [ "$PW_PRE" = "1" ]; then info "кэш браузеров $PW_CACHE существовал ДО сборки (не нами) — пропускаю"
else ok "браузер Playwright не скачивался (кэш $PW_CACHE отсутствует)"; fi
if [ "$HF_PRE" = "0" ] && [ -e "$HF_CACHE" ]; then
  warn "сборка СОЗДАЛА кэш моделей HuggingFace: $HF_CACHE — этого быть не должно"; audit_fail=1
elif [ "$HF_PRE" = "0" ]; then ok "модели HuggingFace не скачивались (кэш $HF_CACHE отсутствует)"; fi
if grep -Eqi 'playwright[^\n]*install (chromium|firefox|webkit)|Downloading browser|huggingface.*download|install-deps' "$PIP_LOG"; then
  warn "в логе установки найдены следы докачки бинарей/браузера — проверьте $PIP_LOG"; audit_fail=1
else ok "в логе установки нет докачек браузера/моделей/системных libs"; fi
[ "$audit_fail" = "0" ] || fail "аудит выявил отклонения (см. ⚠ выше) — сборка НЕ признана чистой"

# ── 8. итог ──────────────────────────────────────────────────────────────────────────────────
"$VPY" -m pip freeze > "$VENV/pip-freeze.txt" 2>/dev/null || true
step "Готово"
ok "Hercules собран в $VENV"
info "запуск:        $HBIN --help    (или активируйте venv: source $VENV/bin/activate)"
info "браузер НЕ докачивался — укажите свой Chromium-движок в окружении Hercules"
info "  (BROWSER_PATH / BROWSER_CHANNEL / CDP_ENDPOINT_URL; HEADLESS=true по умолчанию)."
info "если нужен именно bundled Chromium — поставьте его вручную ОТДЕЛЬНО:"
info "    $VENV/bin/playwright install chromium"
rm -f "$REPORT" 2>/dev/null || true
