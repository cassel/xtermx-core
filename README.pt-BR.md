<p align="center"><img src="Design/icon.png" width="128" alt="Ícone do XTermX"></p>
<h1 align="center">XTermX</h1>
<p align="center"><b>Seus agentes lado a lado. Seus terminais onde você estiver.</b></p>
<p align="center">Terminal nativo para Mac · Node Linux · Sessões remotas criptografadas</p>
<p align="center"><a href="README.md">English</a> · <b>Português</b> · <a href="README.es.md">Español</a> · <a href="README.zh-CN.md">简体中文</a> · <a href="https://cassel.us">C. Cassel</a></p>

XTermX é um ambiente de terminais para quem trabalha com agentes de programação. Rode Claude Code, Codex, Gemini CLI e outras ferramentas lado a lado, dê nomes aos panes e acompanhe quem está trabalhando ou precisa da sua atenção.

**O app para Mac, o node Linux e as bibliotecas deste repositório são abertos sob a licença MIT. O app iOS e o companion do Apple Watch são desenvolvidos separadamente e permanecem proprietários. O lançamento na App Store está previsto; ainda não há link público para download na loja.**

Para usar o companion oficial, acompanhe esta página: o link da App Store será incluído após o lançamento. Para compilar o Mac ou executar um node Linux, siga as instruções abaixo.

## Conheça o fluxo

As imagens são **prévias ilustrativas da documentação**, renderizadas fora da tela com dados fictícios e a paleta do XTermX. Explicam o fluxo, mas não são capturas de um desktop pessoal nem reproduções exatas de uma versão publicada. Nenhuma sessão, conta, pasta ou estatística real foi usada. [Como são geradas](Design/previews/README.md).

![Workspace ilustrativo com quatro panes nomeados e tarefas fictícias](Design/previews/workspace-demo.png)

Nomeie panes como **API**, **Interface**, **Testes** e **Revisão**. Mantenha o agente perto dos testes, navegue pelo teclado e identifique quem está esperando uma resposta.

![Home ilustrativa com contadores e gráfico de tokens fictícios](Design/previews/home-demo.png)

A Home organiza estados dos terminais, limites informados pelos provedores, gráficos locais e atividade recente em seções. Limites de plano e estimativas de tokens têm fontes diferentes; a interface deixa essa distinção visível.

## Recursos

| Área | O que oferece |
|---|---|
| Terminais | Abas, divisões horizontais/verticais, nomes personalizados, equalização e maximização |
| Navegação | Atalhos, troca rápida de terminal, paleta de comandos e movimentação entre panes |
| Agentes | Catálogo de 28 CLIs instaladas no seu `PATH`; integração com Claude Code e Codex |
| Visão geral | Home por seções, atividade recente, histórico local e gráficos de uso |
| Coordenação | Control Rooms, broadcast e ferramentas MCP com escopo e aprovação |
| Aparência | Dez temas, contraste, destaque do pane e personalização de atalhos |
| Trabalho remoto | Conexões entre nodes, SSH, SFTP e edição de texto remoto |
| Continuidade | Companion iOS/Watch separado, com lançamento na App Store previsto |

Também há busca no terminal, ditado no Mac, layouts salvos e visualização em chat para sessões compatíveis. As notificações opcionais podem usar macOS, Telegram ou Slack, conforme sua configuração.

As integrações podem mostrar tarefas, ferramentas recentes, pedidos de autorização e tokens. Percentuais de plano dependem dos dados informados pelo agente/provedor. Estimativas de custo por tokens **não equivalem à cobrança da sua assinatura**. Contas, assinaturas e instalações das CLIs continuam sendo suas.

## Como usar

1. Abra um workspace no Mac e inicie seus agentes instalados.
2. Nomeie cada pane pelo trabalho que ele faz.
3. Acompanhe os terminais ou abra a Home para uma visão geral.
4. Se quiser conectar outro Mac ou Linux, use **Machines → Add machine**.
5. Quando o companion estiver disponível, faça o pareamento em **Remote access** para continuar as mesmas sessões pelo celular.

O código dos aplicativos iOS e Watch e seus materiais de assinatura **não fazem parte deste repositório**. Bibliotecas e protocolo compartilhados podem ser abertos sem abrir essas interfaces proprietárias.

## Compilar o Mac

[Baixar a versão de desenvolvimento para Mac](https://github.com/cassel/xtermx-core/releases/tag/dev-2026.10.19-1300) — universal Apple Silicon + Intel, macOS 15+. Possui assinatura ad-hoc e **não é notarizada pela Apple**; o macOS pode impedir a primeira abertura. O download não inclui os apps proprietários de iOS/Watch.

Para compilar: **macOS 15+**, **Xcode 26+** e **XcodeGen**.

```bash
git clone https://github.com/cassel/xtermx-core.git
cd xtermx-core
xcodegen generate
open XTermX.xcodeproj
```

Selecione **XTermX-macOS**, escolha sua própria equipe Apple em Signing & Capabilities e execute. Certificados, perfis e chaves privadas não estão incluídos.

Para conferir a compilação sem assinar:

```bash
xcodebuild -project XTermX.xcodeproj -scheme XTermX-macOS \
  -destination 'platform=macOS' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

Consulte [BUILDING.md](docs/BUILDING.md) para testes, CLI e distribuição notarizada do Mac. O projeto público do Xcode contém apenas o app Mac.

## Rodar no Linux

Use Swift 6.2+ ou Docker. O instalador compila o node, instala no usuário atual e configura um serviço systemd quando disponível. Leia o script antes de executá-lo no seu servidor.

```bash
git clone https://github.com/cassel/xtermx-core.git
cd xtermx-core
XTERMX_ADDRESSES="node.example.com" ./Server/install.sh
```

Os terminais rodam como o usuário do serviço e usam as ferramentas e credenciais dele. Este lançamento inicial não anexa binários Linux. Valide o funcionamento na sua distribuição.

## Pareamento e permissões

Abra o globo no Mac ou pressione **⌘⇧G**, habilite o acesso remoto e use o QR ou link de pareamento. Esse código é uma credencial: compartilhe apenas com dispositivos confiáveis e nunca publique em imagens.

- Dispositivos já conectados permanecem no histórico como offline após desconectar.
- Cada pane pode ser compartilhado para controle, somente leitura ou marcado como privado.
- O host controla criação remota de terminais, Control Rooms e recebimento de arquivos.
- Receber arquivos exige habilitação. O host define o limite de anexos em Ajustes → Acesso remoto (500 MB por arquivo por padrão), com cota total de armazenamento opcional. Alterações chegam imediatamente aos dispositivos pareados. Envios antigos por Salas e arquivos continuam limitados a 4 MB.
- **Forget all devices** troca o segredo e exige novo pareamento.

Os frames usam ChaCha20-Poly1305 com autenticação, nonces de conexão e contadores contra replay. Portas: **47820** (WebSocket) e **47821** (transporte HTTP compatível com Watch); Bonjour `_xtermx._tcp`.

O alcance depende da sua rede local, VPN e firewall. XTermX não fornece relay ou VPN hospedada. Nomes `.local` normalmente atendem à rede local. Veja [SECURITY.md](SECURITY.md); não alegamos auditoria independente de segurança.

## Atalhos principais

| Atalho | Ação |
|---|---|
| ⌘T / ⌘N | Novo workspace / terminal |
| ⌘D / ⌘⇧D | Dividir à direita / abaixo |
| ⌃ + seta | Focar o pane vizinho |
| ⌃⇧ + seta | Mover o pane para a posição vizinha |
| ⌃Tab | Troca rápida de terminal |
| ⌘⇧M / ⌘P | Maximizar / equalizar |
| ⌘K | Paleta de comandos |
| ⌘B / ⌘⇧B | Barra lateral / painel direito |
| ⌘⌥B | Broadcast de digitação |
| ⌘⇧G | Dispositivos e acesso remoto |

**Settings → Shortcuts** mostra as combinações ativas e permite personalização.

## Ferramentas para agentes

O servidor MCP local fornece criação de panes com aprovação, leitura/envio com escopo, espera por resultados e coordenação de agentes nas Control Rooms. `pane_close` é recusado: fechar panes é uma ação da pessoa. O servidor usa loopback, tokens por pane e rejeita origens de navegador. Habilitar panes criados por agentes é opcional.

## Selecionar texto e abrir links

No Mac, arraste sobre o texto do terminal e pressione **⌘C** para copiar, inclusive em programas que capturam o mouse, como tmux. Segure **Control** sobre um link para destacá-lo e clique para abrir no navegador; **⌘clique** também funciona. Segure **Option** ao clicar ou arrastar para enviar o mouse ao programa do terminal. A cópia automática fica em **Configurações → Terminal → Copiar ao selecionar texto**.

## Desenvolvimento e contribuição

O projeto está em desenvolvimento ativo. O snapshot inicial veio de uma integração privada com 165 testes Swift aprovados e builds Mac/iOS/Watch verdes. Isso não certifica toda combinação de dispositivo físico ou distribuição Linux. A validação da árvore pública está em [BUILDING.md](docs/BUILDING.md).

Veja [CONTRIBUTING.md](CONTRIBUTING.md) para contribuir. Em issues públicas, use dados fictícios: não envie conteúdo real de terminal, QR de pareamento, segredos ou dados de contas.

## Licença e créditos

Copyright © 2026 **C. Cassel** — [cassel.us](https://cassel.us).

Este repositório público usa [MIT](LICENSE). A licença cobre o material publicado aqui; não inclui o código proprietário dos aplicativos iOS/Watch mantidos separadamente nem altera as licenças das dependências.

Emulação: [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm). SSH: [Citadel](https://github.com/orlandos-nl/Citadel). Rede: [SwiftNIO](https://github.com/apple/swift-nio). Geração de projeto: [XcodeGen](https://github.com/yonaskolb/XcodeGen).
