#!/usr/bin/env bash
set -Eeuo pipefail

#by: Vinicius Jose Dias

# ==================== CONFIGURAÇÕES ====================
ANO="2025"
MES="08"
DIA="25"
CICLO="06"          # 00, 06, 12, 18

HORA_INICIAL_FCST=0
HORA_FINAL_FCST=72
PASSO_FCST=3

DIR_BASE="/home/ufsc-lab/Build_WRF/DATA/VINICIUS"
# Forçar origem? opções: auto | nomads | fnl
ORIGEM="auto"
# Paralelismo: 1 (sequencial), 4 ou 8 acelera
THREADS=4
# =======================================================

DATA_URL="${ANO}${MES}${DIA}"
dt_target=$(date -u -d "${ANO}-${MES}-${DIA} ${CICLO}:00:00" +%s || echo 0)
now_utc=$(date -u +%s)
age_sec=$(( now_utc - dt_target ))
nine_days=$((9*24*3600))

# Decide origem
if [[ "$ORIGEM" == "auto" ]]; then
  if (( dt_target>0 && age_sec >= 0 && age_sec < nine_days )); then
    ORIGEM="nomads"   # recente -> GFS 0.25°
  else
    ORIGEM="fnl"      # histórico -> FNL 1.0°
  fi
fi

# Resol/dir
case "$ORIGEM" in
  nomads) RESOL="0p25" ;;
  fnl)    RESOL="1p00" ;;
  *) echo "Origem inválida: $ORIGEM"; exit 2 ;;
esac

DIR_SAIDA="${DIR_BASE}/${DATA_URL}_${CICLO}Z_${RESOL}"
mkdir -p "$DIR_SAIDA"

echo "================================================="
echo "Downloader GFS/FNL"
echo "Data: ${DIA}/${MES}/${ANO}  Ciclo: ${CICLO}Z"
echo "Origem: ${ORIGEM^^}"
echo "Destino: ${DIR_SAIDA}"
echo "================================================="

# ---- helpers ----
tem_cmd(){ command -v "$1" >/dev/null 2>&1; }
url_ok(){ curl -fsI --retry 2 --retry-delay 2 "$1" >/dev/null; }

tmp_urls="$(mktemp)"
> "$tmp_urls"

if [[ "$ORIGEM" == "nomads" ]]; then
  # NOMADS GFS 0.25°
  BASE="https://nomads.ncep.noaa.gov/pub/data/nccf/com/gfs/prod/gfs.${DATA_URL}/${CICLO}/atmos"
  for H in $(seq "$HORA_INICIAL_FCST" "$PASSO_FCST" "$HORA_FINAL_FCST"); do
    printf "%s/gfs.t%sz.pgrb2.0p25.f%03d\n" "$BASE" "$CICLO" "$H" >> "$tmp_urls"
  done
else
  # FNL 1.0° — análises 6/6h a partir de t0
  # Ignora seus H/step e gera sequência 6-hourly até HORA_FINAL_FCST
  steps=$(( HORA_FINAL_FCST / 6 ))
  base_dt="${ANO}-${MES}-${DIA} ${CICLO}:00:00"
  for k in $(seq 0 "$steps"); do
    DSTR=$(date -u -d "${base_dt} + ${k}*6 hours" +%Y%m%d)
    HSTR=$(date -u -d "${base_dt} + ${k}*6 hours" +%H)
    echo "https://nomads.ncep.noaa.gov/pub/data/nccf/com/fnl/prod/fnl.${DSTR}/fnl_${DSTR}_${HSTR}_00.grib2" >> "$tmp_urls"
  done
fi

# Filtra por disponibilidade
tmp_ok="$(mktemp)"; > "$tmp_ok"
while IFS= read -r u; do
  if url_ok "$u"; then
    echo "$u" >> "$tmp_ok"
  else
    echo "AVISO: indisponível -> $(basename "$u")"
  fi
done < "$tmp_urls"

if [[ ! -s "$tmp_ok" ]]; then
  echo "Nada disponível para essa data/ciclo na origem ${ORIGEM^^}."
  [[ "$ORIGEM" == "nomads" ]] && echo "Tente outra data/ciclo ou use ORIGEM=fnl para histórico."
  exit 1
fi

echo ""
echo "Baixando arquivos..."

if tem_cmd aria2c; then
  # rápido e robusto
  aria2c -x8 -s8 -j"$THREADS" -c -d "$DIR_SAIDA" -i "$tmp_ok"
else
  # wget paralelo
  if tem_cmd xargs; then
    < "$tmp_ok" xargs -n1 -P"$THREADS" -I{} wget -c --show-progress -P "$DIR_SAIDA" {}
  else
    while IFS= read -r u; do
      wget -c --show-progress -P "$DIR_SAIDA" "$u"
    done < "$tmp_ok"
  fi
fi

echo ""
echo "================================================="
echo "Concluído! Arquivos em: $DIR_SAIDA"
echo "================================================="
