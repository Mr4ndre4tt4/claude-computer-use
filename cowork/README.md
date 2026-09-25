# Mac Computer Use no Cowork

O Cowork (e as outras superfícies do app Claude fora do Claude Code) não usa plugins do Claude Code. Ele usa servidores MCP locais instalados como **extensão** do app. Esta pasta traz tudo pronto:

| Arquivo | O que é |
|---|---|
| `mac-computer-use.mcpb` | A extensão, com o servidor (binário universal, Apple Silicon + Intel) dentro. |
| `mac-computer-use-skill.zip` | A skill com o fluxo de uso e as regras de segurança, com o texto ajustado para a extensão. |
| `install.sh` | Abre o instalador da extensão e mostra a skill para enviar. |

O plugin do Claude Code continua funcionando como antes. Os dois podem ficar instalados ao mesmo tempo.

## Instalação

Requisitos: macOS 14 ou superior e o app Claude para desktop.

```bash
./cowork/install.sh
```

O script faz três coisas: gera de novo os arquivos, se houver código-fonte; abre o instalador; e mostra a skill no Finder. Depois:

1. **Extensão:** na janela do app Claude, clique em **Instalar**. Sem o script, dê dois cliques em `mac-computer-use.mcpb`, ou arraste o arquivo para Ajustes → Extensões.
2. **Skill:** envie `mac-computer-use-skill.zip` em Ajustes → Capacidades → Skills (*Settings → Capabilities → Skills*).
3. **Permissões:** em Ajustes do Sistema → Privacidade e Segurança, ative **Acessibilidade** e **Gravação de Tela** para o app **Claude**. Se o plugin do Claude Code já funciona no app, essas permissões já estão dadas.
4. Feche o Claude por completo (⌘Q) e abra de novo.

**Teste:** no Cowork, peça *"rode check_permissions"*. A resposta mostra se as duas permissões estão ativas e para qual app. Depois, peça algo simples, como *"leia o estado da Calculadora"*.

## Atualizar

O plugin do Claude Code se atualiza pelo marketplace, mas a extensão não. A cada versão nova:

```bash
git pull && ./cowork/install.sh
```

Confirme a instalação por cima da anterior e reinicie o Claude. Reenvie a skill só se ela tiver mudado.

## Para quem mantém o repositório

- `scripts/pack-mcpb.sh` gera os dois arquivos desta pasta a partir de `bin/computer-use-server`, `mcpb/manifest.template.json` e `skills/mac-computer-use/SKILL.md`. A versão vem de `.claude-plugin/plugin.json`.
- Numa release, rode `scripts/build.sh` e depois `scripts/pack-mcpb.sh`, e faça o commit do `bin/` e desta pasta juntos, para a extensão acompanhar o plugin.
- O manifesto segue o formato MCPB. Para validar, rode `npx @anthropic-ai/mcpb validate manifest.json` no conteúdo extraído do `.mcpb`.
