#!/system/bin/sh

#  Log: /sdcard/c-zram/zram.log

# ── Logger ────────────────────────────────────────────────
LOG_DIR="/sdcard/c-zram"
LOG="$LOG_DIR/zram.log"

# Cria diretório de log
mkdir -p "$LOG_DIR" 2>/dev/null

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG" 2>/dev/null
    # Também copia pro dmesg para facilitar debug via logcat
    echo "ZRAM_OPT: $1" > /dev/kmsg 2>/dev/null || true
}

log "========================================"
log "ZRAM Fresh — iniciando"
log "========================================"

# ── Aguarda boot completar ───────────────────────────────
log "Aguardando boot_completed..."
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 5
done
log "Boot completado."

# Aguarda sdcard ser montado (necessário pro log em /sdcard)
SD_WAIT=0
while [ ! -d "/sdcard/Android" ] && [ "$SD_WAIT" -lt 30 ]; do
    sleep 2
    SD_WAIT=$((SD_WAIT + 2))
done
# Recria o diretório de log agora que o sdcard está montado
mkdir -p "$LOG_DIR" 2>/dev/null
log "Armazenamento disponível. Log ativo em $LOG"

# ── Aguarda zRAM do vendor ser ativada ──────────────────
# O moto.init.rc / init.mt6768.rc inicializa a zRAM após o boot.
# Esperamos até ela aparecer em /proc/swaps antes de assumir.
log "Aguardando zRAM do vendor ser ativada..."
TIMEOUT=60
ELAPSED=0
while ! grep -q "zram0" /proc/swaps 2>/dev/null; do
    sleep 2
    ELAPSED=$((ELAPSED + 2))
    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        log "[AVISO] Timeout de ${TIMEOUT}s esperando zram0. Prosseguindo mesmo assim."
        break
    fi
done
sleep 2  # buffer de segurança pós-detecção

ZRAM_DEV="/dev/block/zram0"
ZRAM_SYS="/sys/block/zram0"

# ── Detecção de RAM total ────────────────────────────────
MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
MEM_TOTAL_MB=$((MEM_TOTAL_KB / 1024))
MEM_TOTAL_GB=$(awk "BEGIN {printf \"%.2f\", $MEM_TOTAL_KB/1024/1024}")
log "RAM total: ${MEM_TOTAL_GB} GB (${MEM_TOTAL_KB} kB)"

# ── Detecção de CPU ──────────────────────────────────────
# Núcleos online
CPU_CORES=$(nproc 2>/dev/null)
if [ -z "$CPU_CORES" ] || [ "$CPU_CORES" -eq 0 ]; then
    CPU_CORES=$(ls -d /sys/devices/system/cpu/cpu[0-9]* 2>/dev/null | wc -l)
fi
[ -z "$CPU_CORES" ] || [ "$CPU_CORES" -eq 0 ] && CPU_CORES=4
log "Núcleos de CPU: $CPU_CORES"

# Clock máximo entre todos os núcleos (em kHz)
MAX_FREQ=0
for freq_file in /sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq; do
    [ -f "$freq_file" ] || continue
    FREQ=$(cat "$freq_file" 2>/dev/null)
    [ -n "$FREQ" ] && [ "$FREQ" -gt "$MAX_FREQ" ] && MAX_FREQ="$FREQ"
done
MAX_FREQ_MHZ=$((MAX_FREQ / 1000))
log "Clock máximo: ${MAX_FREQ_MHZ} MHz (${MAX_FREQ} kHz)"

# ── Seleção de algoritmo de compressão ──────────────────
# Critério:
#   zstd → >= 6 núcleos  E  clock >= 1700 MHz  E  suporte no kernel
#   lz4  → qualquer outro caso (rápido, levíssimo na CPU)
#
# Por que esse critério?
#   zstd tem ~25% melhor ratio que lz4, mas usa ~30% mais CPU.
#   Em SoCs com poucos núcleos ou clock baixo, esse custo impacta
#   a fluidez. Com >= 6 núcleos e >= 1.7GHz o custo é negligenciável.
ALGO="lz4"
ALGO_REASON="padrão seguro (CPU insuficiente para zstd)"

if [ "$CPU_CORES" -ge 6 ] && [ "$MAX_FREQ" -ge 1700000 ]; then
    if [ -f "$ZRAM_SYS/comp_algorithm" ] && grep -q "zstd" "$ZRAM_SYS/comp_algorithm" 2>/dev/null; then
        ALGO="zstd"
        ALGO_REASON="${CPU_CORES} núcleos @ ${MAX_FREQ_MHZ}MHz — suporte confirmado no kernel"
    else
        ALGO_REASON="CPU capaz, mas zstd não disponível no kernel — usando lz4"
    fi
fi
log "Algoritmo selecionado: $ALGO ($ALGO_REASON)"

# ── Cálculo adaptativo do tamanho da zRAM ────────────────
# Percentual baseado na RAM disponível:
#
#  <= 2 GB  →  65%  (dispositivo muito limitado, precisa de swap agressivo)
#   2-4 GB  →  55%  (faixa típica — balanceado)
#   4-6 GB  →  50%  (confortável, swap como suporte)
#   > 6 GB  →  45%  (RAM abundante, zRAM só para picos)
#
if [ "$MEM_TOTAL_MB" -le 2048 ]; then
    PCT=65
elif [ "$MEM_TOTAL_MB" -le 4096 ]; then
    PCT=55
elif [ "$MEM_TOTAL_MB" -le 6144 ]; then
    PCT=50
else
    PCT=45
fi

# Calcula tamanho, arredonda para múltiplo de 256 MB (alinhamento limpo)
ZRAM_MB=$(( MEM_TOTAL_MB * PCT / 100 ))
ZRAM_MB=$(( (ZRAM_MB / 256) * 256 ))

# Limites de segurança
[ "$ZRAM_MB" -lt 256 ]  && ZRAM_MB=256
[ "$ZRAM_MB" -gt 4096 ] && ZRAM_MB=4096

ZRAM_BYTES=$(( ZRAM_MB * 1024 * 1024 ))
log "Tamanho zRAM: ${ZRAM_MB} MB (${PCT}% de ${MEM_TOTAL_MB} MB RAM)"

# ── 1. Desativa zRAM atual ───────────────────────────────
if swapoff "$ZRAM_DEV" 2>/dev/null; then
    log "swapoff OK"
else
    log "[AVISO] swapoff falhou ou zRAM já estava inativa — continuando."
fi

# ── 2. Reset obrigatório ─────────────────────────────────
# Sem o reset, o kernel recusa qualquer mudança em comp_algorithm e disksize.
if echo 1 > "$ZRAM_SYS/reset" 2>/dev/null; then
    log "zRAM reset OK"
else
    log "[ERRO FATAL] Falha no reset da zRAM. Abortando."
    exit 1
fi

# ── 3. Define algoritmo ──────────────────────────────────
if echo "$ALGO" > "$ZRAM_SYS/comp_algorithm" 2>/dev/null; then
    ACTUAL_ALGO=$(grep -o '\[\w*\]' "$ZRAM_SYS/comp_algorithm" 2>/dev/null | tr -d '[]')
    log "comp_algorithm definido: $ACTUAL_ALGO (solicitado: $ALGO)"
else
    log "[AVISO] Falha ao definir comp_algorithm. Kernel manterá o padrão."
fi

# ── 4. Define tamanho ────────────────────────────────────
if echo "$ZRAM_BYTES" > "$ZRAM_SYS/disksize" 2>/dev/null; then
    log "disksize definido: ${ZRAM_BYTES} bytes (${ZRAM_MB} MB)"
else
    log "[ERRO FATAL] Falha ao definir disksize. Abortando."
    exit 1
fi

# ── 5. Formata e ativa como swap ─────────────────────────
MKSWAP_OUT=$(mkswap "$ZRAM_DEV" 2>&1)
log "mkswap: $MKSWAP_OUT"

if swapon "$ZRAM_DEV" 2>/dev/null; then
    log "swapon OK"
else
    log "[ERRO FATAL] swapon falhou."
    exit 1
fi

# ── 6. Parâmetros de memória do kernel ───────────────────

# Swappiness: 100 mantém o padrão agressivo do Android
# (LMKD já governa o comportamento real no Android 10+)
sysctl -w vm.swappiness=100 >> "$LOG" 2>&1

# page-cluster=0: ESSENCIAL para zRAM
# O padrão do kernel é 3 (prefetch de 8 páginas), feito para HDDs.
# zRAM tem latência ~0 e acesso aleatório — prefetch desperdiça
# CPU e RAM sem nenhum ganho. Zerar elimina esse overhead.
sysctl -w vm.page-cluster=0 >> "$LOG" 2>&1

# watermark_boost_factor=0: evita travadas de CPU
# Por padrão, liberação de memória causa picos altos no watermark.
# Zerando, a liberação é linear e suave.
sysctl -w vm.watermark_boost_factor=0 >> "$LOG" 2>&1

# watermark_scale_factor adaptativo:
# Quanto menor a RAM, mais cedo o kernel começa a liberar páginas.
# Evita entrar em situação crítica de repente.
#   <= 2 GB → 150 (~1.5% da RAM como margem antecipada)
#    2-4 GB → 125 (~1.25%)
#    > 4 GB → 100 (~1.0%)
if [ "$MEM_TOTAL_MB" -le 2048 ]; then
    WSF=150
elif [ "$MEM_TOTAL_MB" -le 4096 ]; then
    WSF=125
else
    WSF=100
fi
sysctl -w vm.watermark_scale_factor=$WSF >> "$LOG" 2>&1

log "Parâmetros aplicados:"
log "  vm.swappiness             = 100"
log "  vm.page-cluster           = 0"
log "  vm.watermark_boost_factor = 0"
log "  vm.watermark_scale_factor = $WSF"

# ── Resumo final ─────────────────────────────────────────
log "========================================"
log "ZRAM Fresh — configuração final:"
log "  Dispositivo : $(getprop ro.product.device) / $(getprop ro.product.model)"
log "  RAM total   : ${MEM_TOTAL_GB} GB"
log "  CPU         : ${CPU_CORES} núcleos @ ${MAX_FREQ_MHZ} MHz"
log "  Algoritmo   : $ALGO"
log "  Tamanho     : ${ZRAM_MB} MB"
log "========================================"
