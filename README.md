# Macropad (menu bar)

App nativo para macOS que fica na barra de menus e configura o **macropad de 6 teclas + 1 knob**
vendido no AliExpress (família "CH57x", USB `1189:8890`). É a versão gráfica do CLI
[`macropad`](https://github.com/nacif-software/vibe-coder-keyboard): fala o mesmo protocolo USB,
aceita a mesma sintaxe de ações e lê/grava o mesmo arquivo de layout, então os dois podem ser
usados juntos.

As configurações ficam gravadas na memória do próprio pad — continuam funcionando em qualquer
computador, sem o app aberto.

## O que faz

- **Desenho do pad** com as 6 teclas e o knob (girar ↺, pressionar, girar ↻); clique num slot
  para editar.
- **Editor de ação**
  - *Teclas:* combos (`shift+cmd+4`) e sequências de até 5 passos (`cmd+a, cmd+c`), digitando
    ou **gravando** o atalho no teclado.
  - *Mídia:* volume, mudo, play/pausa, faixa anterior/próxima, brilho.
  - *Mouse:* cliques e rolagem, com modificadores (`ctrl+scroll-up` = zoom).
  - *Nada:* limpa o slot.
- **Teclas de programa**: uma tecla pode abrir um app, um link, rodar um script (zsh) ou um atalho
  do app Atalhos. O pad envia um atalho reservado (⌃⌥⇧⌘ + tecla) que o Macropad registra como
  atalho global — sem pedir permissão de Acessibilidade. O app precisa estar aberto.
- **Preset por app**: troca o preset do pad sozinho conforme o app em uso (ex.: Terminal → Vibe
  Coder, Spotify → Mídia), com um preset padrão opcional para os outros apps.
- **Presets** prontos (Vibe Coder para o Claude Code, Edição, Mídia, Navegação), seus próprios
  presets salvos, importação/exportação em YAML e **Desfazer** depois de aplicar um preset.
- **LED**: desligado / tecla pressionada / arco-íris.
- **Camadas 1–3** (com aviso: neste modelo o firmware ignora a camada e a última gravação vence —
  use *Preset por app* para ter "camadas" de verdade).
- **Status de conexão**: o ícone na barra fica cheio quando o pad está conectado.
- **Identificar teclas**: cada tecla passa a digitar seu número para você descobrir qual é qual;
  depois *Restaurar layout*.
- Abrir automaticamente ao iniciar sessão.

Não pede nenhuma permissão do macOS: o canal de configuração do pad é uma interface USB sem driver,
que o app abre direto via IOUSBLib (a mesma API do libusb) (não é preciso Monitoramento de Entrada nem Acessibilidade).

## Instalar

Requer macOS 13 ou mais novo e as ferramentas de linha de comando do Xcode
(`xcode-select --install`).

```bash
git clone https://github.com/geraldoantonio/macropad-menubar
cd macropad-menubar
./scripts/build-app.sh --install     # compila, copia para /Applications e abre
```

Ou baixe o `Macropad.zip` da [release mais nova](https://github.com/geraldoantonio/macropad-menubar/releases/latest).
Depois de instalado, use ⚙︎ → **Atualizar Macropad…** para pegar versões novas (cada push em `main`
vira uma release). Como o app é assinado só localmente (ad hoc), na primeira vez abra com
clique direito → **Abrir**, ou rode `xattr -dr com.apple.quarantine /Applications/Macropad.app`.

## Arquivos

| Caminho | O que é |
|---|---|
| `~/.config/macropad/layout.yaml` | O que está gravado no pad (o pad não pode ser lido de volta). Compartilhado com o CLI; `$MACROPAD_LAYOUT` muda o caminho. |
| `~/.config/macropad/presets/*.yaml` | Seus presets, no mesmo formato. |
| `~/.config/macropad/app.json` | Configuração só do app: comandos das teclas de programa e regras por app. |
| `~/Library/Logs/Macropad.log` | Saída dos scripts. |

```yaml
led: 1
layers:
  1:
    key1: cmd+c
    key2: cmd+v
    key4: cmd+a, cmd+c
    knob-left: volume-down
    knob-press: mute
    knob-right: volume-up
```

## Sintaxe das ações

| Tipo | Exemplo | Regras |
|---|---|---|
| Combo | `cmd+shift+4` | Modificadores + no máximo uma tecla comum |
| Sequência | `cmd+a, cmd+c` | Até **5** combos separados por vírgula, sem pausas |
| Mídia | `volume-up`, `mute`, `play`, `next`, `prev`, `brightness-up` | Sozinha, sem modificadores |
| Mouse | `click`, `right-click`, `scroll-up`, `ctrl+scroll-down` | Aceita modificadores, fora de sequências |

Modificadores: `ctrl`, `opt`, `shift`, `cmd` (prefixo `r` para o lado direito: `rcmd`).
Use `backspace` ou `forward-delete` (nunca `delete`), e `comma` / `shift+equal` em vez de `,` / `+`.

## Desenvolvimento

```
Sources/MacropadCore     lógica pura: tabelas de teclas, sintaxe, pacotes USB, layout, presets
Sources/MacropadMenuBar  o app: SwiftUI (MenuBarExtra) + IOUSBLib
Tests/                   testes; Fixtures/ tem pacotes gerados pelo CLI Python
```

```bash
swift test                      # confere byte a byte com os pacotes do CLI Python
swift run MacropadMenuBar       # roda sem empacotar
```

Os testes usam pacotes gerados pelo CLI original (`macropad … --dry-run --json`), então qualquer
divergência do protocolo quebra o build. O protocolo está documentado em
[vibe-coder-keyboard/docs/protocol.md](https://github.com/nacif-software/vibe-coder-keyboard/blob/main/docs/protocol.md).

## Licença

MIT. Protocolo, tabelas de teclas e o layout "Vibe Coder" vêm do
[vibe-coder-keyboard](https://github.com/nacif-software/vibe-coder-keyboard) de Ricardo Nacif (MIT).
