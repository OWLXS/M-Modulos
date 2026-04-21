# Módulo Magisk/KernelSU
Este módulo cria e gerencia o usa da zram do dispositivo

# Verificar status por terminal
```bash
free -h
su -c cat /proc/swaps
```
Se aparecer algo como:
```bash
~ $ su -c cat /proc/swaps
Filename                                Type            Size           Used             Priority
/dev/block/zram0                        partition       1835004        535796           -2
~ $ free -h
               total        used        free      shared  buff/cache   available
Mem:           3.6Gi       2.1Gi       271Mi        15Mi       1.3Gi       1.5Gi                                                                Swap:          1.7Gi       523Mi       1.2Gi
~ $
```
Está funcionando ✅

# Ajude
Compatilhe (issues) para ajudar a melhorar o módulo
