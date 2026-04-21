#!/sbin/sh
ui_print "=============================="
ui_print "   ZRAM Fresh"
ui_print "=============================="

# ── Verificação de suporte a zRAM ─────────────────────────
ui_print "- Verificando suporte a zRAM no kernel..."
if [ ! -e "/sys/block/zram0" ]; then
    ui_print "  [ERRO] /sys/block/zram0 não encontrado."
    abort "Instalação cancelada: kernel sem suporte a zRAM."
fi
ui_print "  [OK] zRAM presente no kernel."

# ── Verificação de algoritmos disponíveis ─────────────────
# Nota: no momento da instalação o zram pode ainda não estar inicializado pelo vendor. Se o arquivo não existir ou estiver vazio, damos apenas um aviso — a detecção real ocorre no boot.
ui_print "- Verificando algoritmos de compressão..."
ALGO_FILE="/sys/block/zram0/comp_algorithm"
if [ -f "$ALGO_FILE" ] && [ -s "$ALGO_FILE" ]; then
    ALGOS="$(cat "$ALGO_FILE")"
    ui_print "  Disponíveis: $ALGOS"
    if echo "$ALGOS" | grep -q "zstd"; then
        ui_print "  [OK] zstd disponível — será preferido em CPUs >= 6 núcleos / >= 1.7GHz."
    else
        ui_print "  [AVISO] zstd não encontrado. lz4 será usado como fallback."
    fi
else
    ui_print "  [AVISO] Algoritmos não lidos agora (zRAM ainda não ativa)."
    ui_print "          Detecção automática ocorrerá no primeiro boot."
fi

# ── Permissão de execução ──────────────────────────────────
chmod 755 "$MODPATH/service.sh"

ui_print "- Instalação concluída."
ui_print "  Log salvo em: /sdcard/c-zram/zram.log"
ui_print "  Reinicie o dispositivo para ativar."
ui_print "=============================="
