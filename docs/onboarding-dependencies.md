# Auditoria de instalação em um Mac novo

Escopo: dependências e autorizações consumidas pelo MacCode. As sete etapas anteriores continuam no fluxo: Account, Jev, AI accounts, Auto, Bots, Project e Follow. Antes delas entram **Distill → Permissions → Tools**. Ferramentas opcionais têm instalação dentro do setup; autorizações do sistema continuam sendo decisões do usuário.

| Falta ou problema | Efeito | Tratamento no onboarding / recuperação |
|---|---|---|
| Distill ausente | Contas, modelos e conversas indisponíveis | Download oficial automático, verificação `--version`, progresso real e retry na etapa 1. |
| Distill instalado depois que o app abriu | Serviço de contas tentava executar o nome relativo salvo no lançamento; erro anterior podia continuar visível | Resolve o executável em cada operação, atualiza contas e catálogo ao detectar a instalação e limpa o erro de leitura obsoleto; não exige reiniciar o MacCode. Erros de login independentes continuam visíveis. |
| Duas instalações de Distill ao mesmo tempo | Corrida na troca do binário/symlink | Provisionamento serializado em um ponto compartilhado. |
| Download do script falha | Pipeline de shell podia devolver sucesso | `pipefail`, curl absoluto, retries e limites de tempo. Falha fica visível. |
| PATH mínimo de app aberto pelo Finder | CLI instalado, mas não encontrado | Busca explícita em diretórios oficiais e no runtime gerenciado. |
| Override de Distill incorreto, binário quebrado/antigo ou arquitetura incompatível | Falha ao iniciar ou resposta de contas ilegível | Verificação de execução; mensagem de erro, retry e revisão do caminho em Settings. Um caminho personalizado não é apagado. |
| Git / Command Line Tools ausentes | Histórico, worktrees, checkpoints e ferramentas de desenvolvimento falham | Aciona o instalador nativo da Apple; só marca pronto após Git executar. |
| Instalação Apple pendente, Xcode selecionado inválido ou licença não aceita | Git continua sem funcionar | Estado de atenção e Check again; concluir o diálogo/licença da Apple. |
| Node.js ausente ou antigo | Playwright / Claude SDK não iniciam | Instala Node 24 LTS oficial com SHA-256 em `~/.local/share/maccode-node`; não exige Homebrew. |
| npm/npx ausentes ou PATH do shebang incorreto | Dependências de browser não iniciam | Node gerenciado inclui ambos; resolução e PATH dos filhos usam o mesmo diretório. Não sobrescreve o Node pessoal. O terminal interno também recebe os diretórios do Node e Distill instalados pelo setup, sem editar perfis de shell. |
| mac-use ausente ou não registrado no Distill | Automação do Mac não funciona | Instala release com SHA-256 e registra MCP no Distill; erros aparecem no setup. |
| linux-use ausente | Automação do desktop Linux falha | Instala release com SHA-256 no kit do Bot. Falhas não são tratadas como sucesso. |
| Accessibility negada | Controle de apps/teclado/mouse falha | Etapa 2 solicita e abre a tela correta; estado consultado no macOS ao retornar. |
| Screen Recording negada | Captura da tela falha | Etapa 2 solicita e abre a tela correta; mostra o estado real. Um grant pode exigir reabrir o app/helper. |
| Desktop/Documents/Downloads, volumes externos ou rede negados | Projeto e arquivos inacessíveis | Explicação, check opcional que aciona prompts nativos e atalho para Full Disk Access. |
| Full Disk Access ausente | Prompts por pasta / acesso a áreas protegidas | Atalho para System Settings; nunca é marcado concedido por clicar no botão. |
| Local Network negada, firewall/VPN/proxy | Conexão com iPhone ou serviços locais falha | Explicação na etapa 2; aceitar o prompt ao conectar e revisar Privacy & Security/rede. |
| Camera, microfone ou Apple Events/Automation negados | Recurso específico não funciona | Explicação na etapa 2; solicitações continuam no uso do recurso, sem grants fabricados. |
| Chrome ausente | Browser de Bots e sessões Chrome do usuário indisponíveis | Instala app oficial assinado, em Applications ou na pasta Applications do usuário, sem substituir instalação existente. |
| Extensão Chrome ou native host ausentes | Chrome não se conecta ao MacCode | Reutiliza Set Up Chrome Extension: prepara o helper/pasta e abre o setup; o usuário habilita Load unpacked. Check Connection verifica a conexão. |
| Extensão no perfil errado/desativada | Logins de outro perfil ou sem conexão | Instruções existentes e Check Connection; conexão não é presumida pela instalação. |
| Docker/OrbStack ausente | Computador Linux de Bots indisponível | Botão instala Docker Desktop oficial assinado. OrbStack existente é reutilizado. |
| Docker instalado mas parado, licença/setup pendente ou socket inválido | CLI existe, mas o desktop não inicia | Abre Docker/OrbStack e verifica `docker info`; mostra ação pendente até o daemon responder. Os termos são aceitos pelo usuário. |
| CLI do Docker só na pasta do usuário | App Finder não encontra Docker | Busca também `~/Applications/Docker.app` e `~/.docker/bin`. |
| Imagem Linux, Git/Python/X11/Chromium/Playwright do guest ausentes | Primeiro start do Bot falha | Provisionamento existente baixa/constrói a imagem e instala os pacotes do Dockerfile. A etapa Tools explica internet e espaço extras no primeiro start. |
| Helper privilegiado ausente, versão/owner/mode incorretos | Run as user, tarefas e Insomnia indisponíveis | Instalação opcional pelo bootstrap único existente; verifica owner, modo e versão. Diálogo nativo solicita senha uma vez, sem armazená-la. |
| Conta MacCode ausente, sessão expirada ou serviço indisponível | Sync/acesso remoto indisponíveis | Etapa Account original preservada, com validação e mensagens/retry; pode adiar. |
| Contas AI sem login, sessão expirada, plano/quota/créditos insuficientes | Autenticação/modelos/execução falham | Jev, AI accounts e Auto originais preservados. Instalar software não cria assinatura ou crédito. |
| Auto sem conta/modelo válido | Nenhuma rota disponível | Validação existente; não anuncia perfil pronto sem opções confirmadas pelo Distill. |
| Projeto inexistente, movido, sem permissão ou pasta somente leitura | Abertura/criação falha | Etapa Project e erro existentes; progresso e IDs preservados, sem duplicar projeto/Bot no retry. |
| Internet/DNS/TLS/proxy ou rate limit de GitHub/Node/vendor | Download/checksum/login falham | Erro visível, retries existentes de downloads e botão de retry; sem sucesso falso. |
| Disco cheio, home/App Support não gravável | Instalação ou salvamento do progresso falha | Erro visível; progresso não é anunciado como durável quando o store rejeita a gravação. Liberar espaço/permissão e tentar novamente. |
| Pacote incompleto, assinatura/quarentena ou macOS/CPU não suportado | App/helper/CLI não abre | Usar DMG notarizado para a arquitetura suportada (release macOS arm64, macOS mínimo 14); bundle checker/assinatura e runtime probe. Não se desativa Gatekeeper. |
| Ferramentas específicas de um projeto (Xcode completo, SDK Android, Java, Ruby, sourcekit-lsp, typescript-language-server, pyright/pylsp, gopls, rust-analyzer ou clangd) | Build daquele projeto falha | São requisitos do projeto, não do MacCode; os agentes podem instalá-los ao trabalhar no projeto com as autorizações necessárias. |
| CLI direto legado Codex/Claude/Grok ausente | Apenas o provedor direto escolhido falha | Não é requisito do onboarding Distill; Settings mantém caminhos e recuperação existentes. O fluxo padrão usa as contas pelo Distill. |
| SSH/chaves, credenciais Git ou MCPs de terceiros ausentes | Integração externa específica falha | Configuração própria de cada integração, preservada. Credenciais do usuário não podem ser instaladas automaticamente. |
| Fechar setup incompleto / fechar app | Setup desaparecia definitivamente | Agora retoma no próximo lançamento. Migra os estados legados dismissed/existingUser e preserva escolhas. |
| Skip setup explícito / conclusão | Usuário já dispensou ou concluiu | Persiste a decisão e não abre automaticamente. O menu Set Up MacCode continua disponível. Skip for now de uma etapa continua distinto de conclusão. |

Fontes de implementação: `DistillProvisioner`, `DistillAccounts`, `OnboardingSetup`, `ManagedToolInstaller`, `ComputerUsePermissionBroker`, `HostFileAccessPermissions`, `ChromeExtensionSetup`, `BotComputerDockerResolver`, `BotBrowserPlaywrightHost`, `RunAsUserProcessBootstrap`, `Resources/ComputerGuest/Dockerfile` e `scripts/package-app.sh`.

Downloads oficiais: [Distill](https://github.com/samuelfaj/distill/blob/main/install.sh), [Node.js](https://nodejs.org/dist/latest-v24.x/), [Docker](https://docs.docker.com/desktop/setup/install/mac-install/), [Chrome](https://support.google.com/chrome/answer/95346).
