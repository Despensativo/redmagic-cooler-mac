# Diretrizes do Projeto — Smart Cooler Control (`v3.1`)

## 1. Topologia Dual e Runtime

- **Repositório Git Canônico (SSD Interno APFS)**: `/Users/user/Documents/redmagic-cooler-mac`
- **Workspace Espelho no HD Externo (`--400GB--` APFS)**: `/Volumes/--400GB--/FEITOS COM IA/Controlar Cooler`
- **Paridade Obrigatória**: Ao alterar código, builds ou `.agents/` (`00-aprendizados-ativos.md` / `aprendizados.md`), mantenha paridade explícita entre ambos os diretórios quando solicitado.
- **Stack Nativa macOS**: Swift 5.9+ (`AppKit` + `CoreBluetooth`), código-fonte em `src-swift/`, testes em `tests/main.swift` e empacotamento via `./build.sh` (`--run`, `--with-probes`).

## 2. Guardrails e Memória Ativa

- As regras críticas de protocolo BLE (`0x1011`/`0x1012`/`0x1013` BGR), Step-Ladder, anticondensação (`< 36°C` / `>= 38°C`) e `RunLoop.Mode.common` são carregadas automaticamente via `.agents/rules/00-aprendizados-ativos.md` (`[AL-COOLER-001..010]`).
- Consulte detalhes históricos sob demanda via `rg -n "AL-COOLER-0XX" .agents/aprendizados.md` (não leia o arquivo inteiro no Turno 1).
- Nunca distribua builds sem validar assinatura ad-hoc no `./build.sh` (CoreBluetooth exige bundle assinado para liberar o entitlement Bluetooth).
