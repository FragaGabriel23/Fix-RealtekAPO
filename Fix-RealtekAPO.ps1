<#
.SYNOPSIS
    Stops the Realtek audio service from injecting its APOs (Audio Processing
    Objects) into audio endpoints that belong to other manufacturers.

.DESCRIPTION
    Typical symptoms:
      - USB / wireless headset with fluctuating gain, crackling or popping
      - Volume rising and falling on its own
      - Per-application volume control behaving erratically
      - The problem returns after every reboot, even once fixed
      - Uninstalling the headset software "fixes" it, at the cost of its features

    Cause:
    The Realtek Audio Universal Service walks the Windows audio endpoints and
    appends Realtek's APOs to the effects chain of devices that are not Realtek.
    Two audio processors then act on the same stream, producing the symptoms
    above.

    What this tool does:
      1. Detects the Realtek service automatically (its name varies by version)
      2. Lists the audio endpoints and flags the contaminated ones
      3. Cleans existing contamination, preserving THX / Dolby / etc.
      4. Applies a permanent block using the Windows "per-service SID" feature,
         denying write access to the Realtek service alone on that endpoint
      5. Reverts everything on request

    Nothing is uninstalled. Realtek onboard audio keeps working normally.

.PARAMETER Language
    Interface language: 'en' (English) or 'pt' (Portugues do Brasil).
    When omitted, the script guesses from the system culture and asks.

.EXAMPLE
    .\Fix-RealtekAPO.ps1
    .\Fix-RealtekAPO.ps1 -Language pt

.NOTES
    Run from an ELEVATED PowerShell (Administrator).
    Registry backups (.reg) are written before any change.

    Tested on Windows 10 / 11 x64.
    License: MIT
#>

[CmdletBinding()]
param(
    [ValidateSet('en', 'pt')]
    [string]$Language
)

$ErrorActionPreference = 'Stop'

# ==============================================================================
#  LOCALIZATION
#
#  Every user-facing string lives in this table. Code, comments and identifiers
#  stay in English so the script remains maintainable by non-Portuguese readers.
#  Placeholders use the PowerShell -f operator: {0}, {1}, ...
# ==============================================================================

$script:Messages = @{

    # ---- language picker ----------------------------------------------------
    'lang.prompt'            = @{ en = 'Choose language / Escolha o idioma'; pt = 'Choose language / Escolha o idioma' }
    'lang.optionEn'          = @{ en = '[1] English'; pt = '[1] English' }
    'lang.optionPt'          = @{ en = '[2] Portugues (Brasil)'; pt = '[2] Portugues (Brasil)' }
    'lang.choice'            = @{ en = 'Option'; pt = 'Opcao' }

    # ---- generic ------------------------------------------------------------
    'common.yes'             = @{ en = '[Y/n]'; pt = '[S/n]' }
    'common.yesNo'           = @{ en = '[y/N]'; pt = '[s/N]' }
    'common.pause'           = @{ en = 'Press ENTER to return to the menu...'; pt = 'Pressione ENTER para voltar ao menu...' }
    'common.option'          = @{ en = 'Option'; pt = 'Opcao' }
    'common.cancelled'       = @{ en = 'Cancelled.'; pt = 'Cancelado.' }
    'common.nothingSelected' = @{ en = 'Nothing selected.'; pt = 'Nada selecionado.' }
    'common.error'           = @{ en = 'ERROR: {0}'; pt = 'ERRO: {0}' }
    'common.warning'         = @{ en = 'warning: {0}'; pt = 'aviso: {0}' }
    'common.empty'           = @{ en = '(empty)'; pt = '(vazio)' }
    'common.detecting'       = @{ en = '  Detecting service and audio devices...'; pt = '  Detectando servico e dispositivos de audio...' }
    'common.bye'             = @{ en = '  Goodbye.'; pt = '  Ate mais.' }

    # ---- administrator check ------------------------------------------------
    'admin.required'         = @{ en = '  ERROR: this script must be run as ADMINISTRATOR.'; pt = '  ERRO: este script precisa ser executado como ADMINISTRADOR.' }
    'admin.howTitle'         = @{ en = '  How to do it:'; pt = '  Como fazer:' }
    'admin.how1'             = @{ en = '    1. Close this window'; pt = '    1. Feche esta janela' }
    'admin.how2'             = @{ en = '    2. Right-click the Start menu'; pt = '    2. Clique com o botao direito no menu Iniciar' }
    'admin.how3'             = @{ en = '    3. Choose "Terminal (Admin)" or "PowerShell (Admin)"'; pt = '    3. Escolha "Terminal (Administrador)" ou "PowerShell (Admin)"' }
    'admin.how4'             = @{ en = '    4. Go to the script folder and run it again'; pt = '    4. Navegue ate a pasta do script e execute novamente' }
    'admin.policyHint'       = @{ en = '  If you get an execution policy error, run this first:'; pt = '  Se aparecer erro de politica de execucao, rode antes:' }

    # ---- menu ---------------------------------------------------------------
    'menu.banner'            = @{ en = '#   REALTEK APO FIX FOR THIRD-PARTY AUDIO DEVICES           #'; pt = '#   CORRETOR DE APOs REALTEK EM DISPOSITIVOS DE TERCEIROS   #' }
    'menu.service'           = @{ en = '   Realtek service : '; pt = '   Servico Realtek : ' }
    'menu.serviceNotFound'   = @{ en = '   Realtek service : not found'; pt = '   Servico Realtek : nao encontrado' }
    'menu.contamination'     = @{ en = '   Contamination   : '; pt = '   Contaminacao    : ' }
    'menu.contaminationNone' = @{ en = 'none detected'; pt = 'nenhuma detectada' }
    'menu.contaminationSome' = @{ en = '{0} device(s) affected'; pt = '{0} dispositivo(s) afetado(s)' }
    'menu.blocks'            = @{ en = '   Blocks          : '; pt = '   Bloqueios       : ' }
    'menu.blocksActive'      = @{ en = '{0} active'; pt = '{0} ativo(s)' }
    'menu.opt1'              = @{ en = '   [1] Diagnose             see the current state'; pt = '   [1] Diagnostico          ver o estado atual' }
    'menu.opt2'              = @{ en = '   [2] Clean contamination  remove the stray Realtek APOs'; pt = '   [2] Limpar contaminacao  remove os APOs Realtek indevidos' }
    'menu.opt3'              = @{ en = '   [3] Apply block          clean + prevent it from returning'; pt = '   [3] Aplicar bloqueio     limpa + impede que volte' }
    'menu.opt4'              = @{ en = '   [4] Revert block         undo the protection'; pt = '   [4] Reverter bloqueio    desfaz a protecao' }
    'menu.opt5'              = @{ en = '   [5] Service control      stop / disable / re-enable'; pt = '   [5] Controlar o servico  parar / desativar / reativar' }
    'menu.opt6'              = @{ en = '   [6] Backups              list the backups created'; pt = '   [6] Backups              lista os backups gerados' }
    'menu.opt7'              = @{ en = '   [7] About the problem    explanation and recommended order'; pt = '   [7] Sobre o problema     explicacao e ordem recomendada' }
    'menu.opt8'              = @{ en = '   [8] Idioma               mudar para portugues'; pt = '   [8] Language             switch to English' }
    'menu.opt0'              = @{ en = '   [0] Exit'; pt = '   [0] Sair' }

    # ---- diagnosis ----------------------------------------------------------
    'diag.title'             = @{ en = 'DIAGNOSIS'; pt = 'DIAGNOSTICO' }
    'diag.serviceSection'    = @{ en = 'Realtek service'; pt = 'Servico Realtek' }
    'diag.serviceName'       = @{ en = '    Internal name : {0}'; pt = '    Nome interno : {0}' }
    'diag.serviceDisplay'    = @{ en = '    Display name  : {0}'; pt = '    Exibicao     : {0}' }
    'diag.serviceState'      = @{ en = '    State         : {0} / {1}'; pt = '    Estado       : {0} / {1}' }
    'diag.serviceSid'        = @{ en = '    Service SID   : {0}'; pt = '    SID          : {0}' }
    'diag.serviceMissing'    = @{ en = '    No Realtek audio service was found on this machine.'; pt = '    Nenhum servico de audio Realtek encontrado nesta maquina.' }
    'diag.serviceMissingWhy' = @{ en = '    (without a Realtek service, this particular problem does not apply)'; pt = '    (se nao ha servico Realtek, este problema especifico nao se aplica)' }
    'diag.endpointsSection'  = @{ en = 'Active audio endpoints'; pt = 'Endpoints de audio ativos' }
    'diag.resultSection'     = @{ en = 'Result'; pt = 'Resultado' }
    'diag.resultClean'       = @{ en = '    No Realtek contamination detected.'; pt = '    Nenhuma contaminacao Realtek detectada.' }
    'diag.resultDirty'       = @{ en = '    {0} endpoint(s) carrying stray Realtek APOs:'; pt = '    {0} endpoint(s) com APOs Realtek indevidos:' }
    'diag.blockActive'       = @{ en = '    block active: '; pt = '    bloqueio ativo: ' }
    'diag.blockYes'          = @{ en = 'YES'; pt = 'SIM' }
    'diag.blockNo'           = @{ en = 'no'; pt = 'nao' }
    'diag.protectedSection'  = @{ en = 'Devices with a block applied'; pt = 'Dispositivos com bloqueio aplicado' }
    'diag.protectedClean'    = @{ en = 'clean'; pt = 'limpo' }
    'diag.protectedDirty'    = @{ en = 'still contaminated - run a clean'; pt = 'ainda contaminado - limpe' }
    'diag.noFxChain'         = @{ en = '    (this endpoint has no effects chain yet)'; pt = '    (este endpoint ainda nao tem cadeia de efeitos)' }

    # ---- endpoint labels ----------------------------------------------------
    'ep.contaminated'        = @{ en = 'CONTAMINATED'; pt = 'CONTAMINADO' }
    'ep.realtekNative'       = @{ en = 'Realtek (native)'; pt = 'Realtek (nativo)' }
    'ep.ok'                  = @{ en = 'ok'; pt = 'ok' }
    'ep.noFx'                = @{ en = 'no FX chain'; pt = 'sem cadeia FX' }
    'ep.active'              = @{ en = 'active'; pt = 'ativo' }
    'ep.inactive'            = @{ en = 'inactive({0})'; pt = 'inativo({0})' }
    'ep.noneFound'           = @{ en = '    (no endpoints found)'; pt = '    (nenhum endpoint encontrado)' }
    'ep.fxSfx'               = @{ en = 'SFX (stream)'; pt = 'SFX (stream)' }
    'ep.fxMfx'               = @{ en = 'MFX (mode)'; pt = 'MFX (modo)' }
    'ep.fxSfxOffload'        = @{ en = 'SFX offload'; pt = 'SFX offload' }
    'ep.fxMfxOffload'        = @{ en = 'MFX offload'; pt = 'MFX offload' }

    # ---- selection ----------------------------------------------------------
    'sel.noCandidates'       = @{ en = 'No active non-Realtek device was found.'; pt = 'Nenhum dispositivo nao-Realtek ativo foi encontrado.' }
    'sel.hintNumbers'        = @{ en = 'Type the numbers separated by commas (e.g. 1,2)'; pt = 'Digite os numeros separados por virgula (ex: 1,2)' }
    'sel.hintKeys'           = @{ en = 'ENTER = all contaminated   |   A = all   |   C = cancel'; pt = 'ENTER = todos os contaminados   |   T = todos   |   C = cancelar' }
    'sel.choose'             = @{ en = 'Choose'; pt = 'Escolha' }
    'sel.noneContaminated'   = @{ en = 'Nothing is contaminated; nothing selected.'; pt = 'Nenhum contaminado; nada selecionado.' }
    'sel.titleClean'         = @{ en = 'Devices to clean'; pt = 'Dispositivos para limpar' }
    'sel.titleProtect'       = @{ en = 'Devices to protect'; pt = 'Dispositivos a proteger' }

    # ---- backup -------------------------------------------------------------
    'backup.saved'           = @{ en = '    backup: {0}'; pt = '    backup: {0}' }
    'backup.failed'          = @{ en = '    BACKUP FAILED: {0}'; pt = '    FALHA no backup: {0}' }
    'backup.skipDevice'      = @{ en = '    backup failed; skipping this device'; pt = '    backup falhou; pulando este dispositivo' }
    'backup.title'           = @{ en = 'BACKUPS'; pt = 'BACKUPS' }
    'backup.noneYet'         = @{ en = 'No backup has been created yet.'; pt = 'Nenhum backup foi criado ainda.' }
    'backup.expectedPath'    = @{ en = 'Expected location: {0}'; pt = 'Local previsto: {0}' }
    'backup.folderEmpty'     = @{ en = 'The folder exists but is empty.'; pt = 'Pasta existe, mas esta vazia.' }
    'backup.folder'          = @{ en = 'Folder: {0}'; pt = 'Pasta: {0}' }
    'backup.restoreHint'     = @{ en = 'To restore a backup, run as administrator:'; pt = 'Para restaurar um backup, rode como administrador:' }
    'backup.restoreNote1'    = @{ en = 'Note: importing restores values but does not remove keys created'; pt = 'Obs: a importacao restaura valores, mas nao remove chaves criadas' }
    'backup.restoreNote2'    = @{ en = 'after the backup. Use option 2 (Clean) for that.'; pt = 'depois do backup. Use a opcao 2 (Limpar) para isso.' }

    # ---- cleaning -----------------------------------------------------------
    'clean.title'            = @{ en = 'CLEAN CURRENT CONTAMINATION'; pt = 'LIMPAR CONTAMINACAO ATUAL' }
    'clean.intro1'           = @{ en = 'Removes the Realtek APOs from the effects chain, preserving'; pt = 'Remove os APOs da Realtek da cadeia de efeitos, preservando' }
    'clean.intro2'           = @{ en = 'THX, Dolby and any other legitimate effects of the device.'; pt = 'THX, Dolby e quaisquer outros efeitos legitimos do dispositivo.' }
    'clean.confirm'          = @{ en = 'Back up and clean {0} device(s)?'; pt = 'Fazer backup e limpar {0} dispositivo(s)?' }
    'clean.nothingHere'      = @{ en = '    no Realtek entries found on this endpoint'; pt = '    nada de Realtek encontrado neste endpoint' }
    'clean.nothingToDo'      = @{ en = '    nothing to clean (no FX chain)'; pt = '    nada a limpar (sem cadeia FX)' }
    'clean.capxAsk'          = @{ en = '    Also remove the CAPX subkey created by the service?'; pt = '    Remover tambem a subchave CAPX criada pelo servico?' }
    'clean.capxRemoved'      = @{ en = '    CAPX subkey removed'; pt = '    subchave CAPX removida' }
    'clean.restartHint'      = @{ en = 'Restart the Windows audio service to apply:'; pt = 'Reinicie o servico de audio do Windows para aplicar:' }
    'clean.warnReturns'      = @{ en = 'NOTE: without the block, contamination comes back on the next run.'; pt = 'ATENCAO: sem o bloqueio, a contaminacao volta na proxima execucao.' }

    # ---- block --------------------------------------------------------------
    'block.title'            = @{ en = 'APPLY PERMANENT BLOCK'; pt = 'APLICAR BLOQUEIO PERMANENTE' }
    'block.howTitle'         = @{ en = 'How it works:'; pt = 'Como funciona:' }
    'block.how1'             = @{ en = '  1. Windows gives the Realtek service an identity of its own'; pt = '  1. O Windows da ao servico Realtek uma identidade propria' }
    'block.how1b'            = @{ en = '     (the "per-service SID" feature, officially supported)'; pt = '     (recurso "SID por servico", suportado oficialmente)' }
    'block.how2'             = @{ en = '  2. A rule is applied denying write access to that identity alone'; pt = '  2. E aplicada uma regra negando escrita APENAS a essa identidade' }
    'block.how2b'            = @{ en = '     on the effects key of the chosen device'; pt = '     na chave de efeitos do dispositivo escolhido' }
    'block.notTitle'         = @{ en = 'What is NOT affected:'; pt = 'O que NAO e afetado:' }
    'block.not1'             = @{ en = '  - Synapse, THX, Dolby and other apps keep configuring normally'; pt = '  - Synapse, THX, Dolby e demais apps continuam configurando normalmente' }
    'block.not2'             = @{ en = '  - Realtek onboard audio keeps all of its effects'; pt = '  - O audio Realtek onboard continua com todos os efeitos' }
    'block.not3'             = @{ en = '  - No driver or service is uninstalled'; pt = '  - Nenhum driver ou servico e desinstalado' }
    'block.confirm'          = @{ en = 'Apply the block to {0} device(s)?'; pt = 'Aplicar bloqueio em {0} dispositivo(s)?' }
    'block.serviceMissing'   = @{ en = 'Realtek service not found - nothing to block.'; pt = 'Servico Realtek nao encontrado - nada a bloquear.' }
    'block.stopSection'      = @{ en = 'Stopping the service'; pt = 'Parando o servico' }
    'block.stopped'          = @{ en = '    service stopped'; pt = '    servico parado' }
    'block.alreadyStopped'   = @{ en = '    service was already stopped'; pt = '    servico ja estava parado' }
    'block.sidSection'       = @{ en = 'Enabling the per-service SID'; pt = 'Ativando SID por servico' }
    'block.sidAlready'       = @{ en = '    SID already enabled ({0})'; pt = '    SID ja ativo ({0})' }
    'block.sidEnabled'       = @{ en = '    per-service SID enabled'; pt = '    SID por servico ativado' }
    'block.sidFailed'        = @{ en = '    FAILED to enable the SID: {0}'; pt = '    FALHA ao ativar o SID: {0}' }
    'block.sidAbort'         = @{ en = 'Could not enable the service SID. Aborting.'; pt = 'Nao foi possivel ativar o SID. Abortando.' }
    'block.applySection'     = @{ en = 'Backup, cleanup and block'; pt = 'Backup, limpeza e bloqueio' }
    'block.noFxInherit'      = @{ en = '    FxProperties missing: applying on the endpoint (inherited)'; pt = '    FxProperties ausente: aplicando no endpoint (com heranca)' }
    'block.currentOwner'     = @{ en = '    current owner: {0}'; pt = '    proprietario atual: {0}' }
    'block.applied'          = @{ en = '    block applied to: {0}'; pt = '    bloqueio aplicado em: {0}' }
    'block.errAdmin'         = @{ en = '    Confirm PowerShell was opened as Administrator.'; pt = '    Confirme que o PowerShell foi aberto como Administrador.' }
    'block.errAv1'           = @{ en = '    If it persists, security software may be preventing'; pt = '    Se persistir, algum antivirus/protecao pode estar impedindo' }
    'block.errAv2'           = @{ en = '    registry permission changes.'; pt = '    alteracoes de permissao no registro.' }
    'block.nextSection'      = @{ en = 'Next steps'; pt = 'Proximos passos' }
    'block.next1'            = @{ en = '1. Set the Realtek service back to Automatic, if you want it running:'; pt = '1. Deixe o servico Realtek em Automatico, se desejar:' }
    'block.next2'            = @{ en = '2. RESTART the computer.'; pt = '2. REINICIE o computador.' }
    'block.next2b'           = @{ en = '   (the service runs at every startup and at other moments during'; pt = '   (o servico roda a cada inicializacao e tambem em outros momentos' }
    'block.next2c'           = @{ en = '    normal use, reapplying the change each time it runs)'; pt = '    de uso, reaplicando a alteracao a cada execucao)' }
    'block.next3'            = @{ en = '3. Run option 1 (Diagnose) afterwards to confirm.'; pt = '3. Rode a opcao 1 (Diagnostico) depois para conferir.' }
    'block.fallback1'        = @{ en = 'If it still gets contaminated, whatever writes is not this service;'; pt = 'Se ainda assim contaminar, quem escreve nao e este servico;' }
    'block.fallback2'        = @{ en = 'in that case use option 4 to revert and option 5 to disable the'; pt = 'nesse caso use a opcao 4 para reverter e a opcao 5 para desativar' }
    'block.fallback3'        = @{ en = 'service, which is the guaranteed fallback.'; pt = 'o servico, que e a alternativa garantida.' }

    # ---- revert -------------------------------------------------------------
    'revert.title'           = @{ en = 'REVERT BLOCK'; pt = 'REVERTER BLOQUEIO' }
    'revert.none'            = @{ en = 'No applied block was found.'; pt = 'Nenhum bloqueio aplicado foi encontrado.' }
    'revert.section'         = @{ en = 'Devices with a block'; pt = 'Dispositivos com bloqueio' }
    'revert.confirm'         = @{ en = 'Remove the block from every listed device?'; pt = 'Remover o bloqueio de todos os listados?' }
    'revert.removed'         = @{ en = '    block removed from: {0}'; pt = '    bloqueio removido de: {0}' }
    'revert.notFoundHere'    = @{ en = '    no block found on this endpoint'; pt = '    nenhum bloqueio encontrado neste endpoint' }
    'revert.ownerRestored'   = @{ en = '    original owner restored'; pt = '    proprietario original restaurado' }
    'revert.ownerFailed'     = @{ en = '    warning: could not restore the original owner'; pt = '    aviso: nao foi possivel restaurar o proprietario' }
    'revert.sidNote'         = @{ en = 'The per-service SID stays enabled (harmless).'; pt = 'O SID por servico permanece ativo (inofensivo).' }
    'revert.sidDisable'      = @{ en = 'To disable it too:  sc.exe sidtype {0} none'; pt = 'Para desativa-lo:  sc.exe sidtype {0} none' }

    # ---- service control ----------------------------------------------------
    'svc.title'              = @{ en = 'REALTEK SERVICE CONTROL'; pt = 'CONTROLAR O SERVICO REALTEK' }
    'svc.notFound'           = @{ en = 'Realtek service not found.'; pt = 'Servico Realtek nao encontrado.' }
    'svc.name'               = @{ en = 'Service : {0}'; pt = 'Servico : {0}' }
    'svc.state'              = @{ en = 'State   : {0}'; pt = 'Estado  : {0}' }
    'svc.startup'            = @{ en = 'Startup : {0}'; pt = 'Inicio  : {0}' }
    'svc.warn1'              = @{ en = 'Disabling the service is the most reliable fix, but you lose the'; pt = 'Desativar o servico e a solucao mais garantida, porem voce perde' }
    'svc.warn2'              = @{ en = 'Realtek Audio Console effects on the built-in speakers.'; pt = 'os efeitos do Realtek Audio Console no audio interno do aparelho.' }
    'svc.warn3'              = @{ en = 'Sound playback itself does NOT stop working.'; pt = 'A reproducao de som NAO para de funcionar.' }
    'svc.opt1'               = @{ en = '[1] Disable service (stop and mark as Disabled)'; pt = '[1] Desativar servico (para e marca como Desabilitado)' }
    'svc.opt2'               = @{ en = '[2] Re-enable service (Automatic + start)'; pt = '[2] Reativar servico (Automatico + iniciar)' }
    'svc.opt3'               = @{ en = '[3] Just stop it now (keep the startup type)'; pt = '[3] Apenas parar agora (sem mudar o tipo de inicio)' }
    'svc.opt0'               = @{ en = '[0] Back'; pt = '[0] Voltar' }
    'svc.doneDisabled'       = @{ en = 'Service stopped and disabled.'; pt = 'Servico parado e desabilitado.' }
    'svc.doneEnabled'        = @{ en = 'Service set to Automatic and started.'; pt = 'Servico em Automatico e iniciado.' }
    'svc.doneStopped'        = @{ en = 'Service stopped.'; pt = 'Servico parado.' }

    # ---- about --------------------------------------------------------------
    'about.title'            = @{ en = 'ABOUT THE PROBLEM'; pt = 'SOBRE O PROBLEMA' }
    'about.sympTitle'        = @{ en = 'SYMPTOMS'; pt = 'SINTOMAS' }
    'about.symp1'            = @{ en = '  USB or wireless headset/speakers with fluctuating gain, hiss,'; pt = '  Headset ou caixa de som USB/wireless com ganho oscilando, chiado,' }
    'about.symp2'            = @{ en = '  crackling, unstable volume, or per-app volume control that stops'; pt = '  estalos, volume instavel ou controle de volume por aplicativo que' }
    'about.symp3'            = @{ en = '  working. The problem returns after every reboot.'; pt = '  para de funcionar. O problema volta a cada reinicializacao.' }
    'about.causeTitle'       = @{ en = 'CAUSE'; pt = 'CAUSA' }
    'about.cause1'           = @{ en = '  The Realtek audio service walks the Windows audio endpoints and'; pt = '  O servico de audio da Realtek percorre os endpoints de audio do' }
    'about.cause2'           = @{ en = '  appends its APOs (effects) to the effects chain of devices that'; pt = '  Windows e anexa os APOs (efeitos) da Realtek a cadeia de efeitos de' }
    'about.cause3'           = @{ en = '  are not Realtek. With two audio processors acting on the same'; pt = '  dispositivos que nao sao Realtek. Com dois processadores de audio' }
    'about.cause4'           = @{ en = '  stream, the symptoms above appear.'; pt = '  atuando sobre o mesmo fluxo, surgem os sintomas acima.' }
    'about.regNote'          = @{ en = '  The effects chain is stored at:'; pt = '  A cadeia de efeitos fica registrada em:' }
    'about.orderTitle'       = @{ en = 'RECOMMENDED ORDER'; pt = 'ORDEM RECOMENDADA' }
    'about.order1'           = @{ en = '  1) Diagnose  - confirm this is your case'; pt = '  1) Diagnostico  - confirma se o seu caso e este' }
    'about.order2'           = @{ en = '  2) Block     - cleans and protects (backs up first)'; pt = '  2) Bloquear     - limpa e aplica a protecao (faz backup antes)' }
    'about.order3'           = @{ en = '  3) Reboot    - the service also runs during normal use'; pt = '  3) Reiniciar    - o servico tambem roda durante o uso normal' }
    'about.order4'           = @{ en = '  4) Diagnose  - check the result'; pt = '  4) Diagnostico  - confere o resultado' }
    'about.failTitle'        = @{ en = 'IF THE BLOCK DOES NOT HOLD'; pt = 'SE O BLOQUEIO NAO SEGURAR' }
    'about.fail1'            = @{ en = '  It means whatever writes is not this service, but another'; pt = '  Significa que quem escreve nao e este servico, e sim outro' }
    'about.fail2'            = @{ en = '  component (likely the driver itself, via PnP).'; pt = '  componente (provavelmente o proprio driver, via PnP).' }
    'about.fail3'            = @{ en = '  The guaranteed alternative is disabling the service (option 5),'; pt = '  A alternativa garantida e desativar o servico (opcao 5),' }
    'about.fail4'            = @{ en = '  which does not stop built-in audio from working - it only removes'; pt = '  o que nao impede o audio interno de funcionar - apenas remove os' }
    'about.fail5'            = @{ en = '  the Realtek Audio Console effects.'; pt = '  efeitos do Realtek Audio Console.' }
    'about.warnTitle'        = @{ en = 'DISCLAIMER'; pt = 'AVISO' }
    'about.warn1'            = @{ en = '  This tool changes Windows registry permissions and values.'; pt = '  Esta ferramenta altera permissoes e valores do registro do Windows.' }
    'about.warn2'            = @{ en = '  Backups are created automatically, but use at your own risk.'; pt = '  Backups sao gerados automaticamente, mas use por sua conta e risco.' }

    # ---- privileges ---------------------------------------------------------
    'priv.loadFailed'        = @{ en = '    warning: could not load the privilege helper'; pt = '    aviso: nao foi possivel carregar o auxiliar de privilegios' }
}

# Interface language, decided at startup.
$script:Language = 'en'

function Get-Text {
    <#
        Returns the localized string for a key, optionally formatted.
        Falls back to English and then to the key itself, so a missing entry
        never breaks the script.
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [object[]]$FormatArgs
    )

    $entry = $script:Messages[$Key]
    if (-not $entry) { return $Key }

    $text = $entry[$script:Language]
    if (-not $text) { $text = $entry['en'] }
    if (-not $text) { return $Key }

    if ($FormatArgs -and $FormatArgs.Count -gt 0) {
        try { return ($text -f $FormatArgs) } catch { return $text }
    }
    return $text
}

# Short alias used throughout the script.
Set-Alias -Name T -Value Get-Text -Scope Script

# ==============================================================================
#  CONFIGURATION
# ==============================================================================

# Backups land on the Desktop; fall back to the user profile, then to TEMP,
# in case the Desktop folder is redirected or unavailable.
$script:BackupRoot = [Environment]::GetFolderPath('Desktop')
if ([string]::IsNullOrWhiteSpace($script:BackupRoot)) {
    $script:BackupRoot = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'Desktop' } else { $null }
}
if ([string]::IsNullOrWhiteSpace($script:BackupRoot) -or -not (Test-Path $script:BackupRoot)) {
    $script:BackupRoot = if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:TEMP }
}
$script:BackupFolder = Join-Path $script:BackupRoot 'RealtekAPOFix_Backups'

$script:MMDeviceRoots = @{
    'Render'  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
    'Capture' = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture'
}

# Effects-chain property set (FMTID) and the property IDs that matter:
#   ,13 = SFX (stream effects)     ,19 = SFX offload
#   ,14 = MFX (mode effects)       ,20 = MFX offload
$script:FxFmtId = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d}'

$script:FxPropertyLabels = [ordered]@{
    "$($script:FxFmtId),13" = 'ep.fxSfx'
    "$($script:FxFmtId),14" = 'ep.fxMfx'
    "$($script:FxFmtId),19" = 'ep.fxSfxOffload'
    "$($script:FxFmtId),20" = 'ep.fxMfxOffload'
}

# Endpoint identification properties.
$script:PropDevicePath  = '{b3f8fa53-0004-438e-9003-51a46e139bfc},2'
$script:PropFriendly    = '{a45c254e-df1c-4efd-8020-67d146a850e0},2'
$script:PropDescription = '{b3f8fa53-0004-438e-9003-51a46e139bfc},6'

# CAPX context subkey the Realtek service creates inside an endpoint.
$script:CapxSubKey = '{12325c6d-6d93-4ab3-bff6-d04968d361dd}'

# Pattern identifying a binary or service as belonging to Realtek.
$script:RealtekPattern = 'rtk|realtek'

# Built-in Administrators group.
$script:AdminsSid = 'S-1-5-32-544'

# ==============================================================================
#  CONSOLE HELPERS
# ==============================================================================

function Write-Line {
    param([string]$Text = '', [string]$Color = 'Gray')
    if ($Text -eq '') { Write-Host '' } else { Write-Host $Text -ForegroundColor $Color }
}

function Write-Header {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor DarkCyan
}

function Write-Section {
    param([string]$Text)
    Write-Host ''
    $padding = [Math]::Max(0, 68 - $Text.Length)
    Write-Host ("-- $Text " + ('-' * $padding)) -ForegroundColor DarkGray
}

function Confirm-Action {
    param([string]$Question, [switch]$DefaultNo)
    $suffix = if ($DefaultNo) { T 'common.yesNo' } else { T 'common.yes' }
    $answer = Read-Host "$Question $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return (-not $DefaultNo) }
    # accepts S (sim) and Y (yes) so it works in both languages
    return ($answer -match '^[SsYy]')
}

function Wait-Menu {
    Write-Host ''
    Write-Host (T 'common.pause') -ForegroundColor DarkGray
    [void](Read-Host)
}

function Test-Administrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ==============================================================================
#  PRIVILEGES AND REGISTRY ACL
#
#  The audio keys are owned by TrustedInstaller. Being an Administrator grants
#  the right to TAKE ownership, but not to change permissions until ownership
#  is actually taken -- and taking it requires enabling SeTakeOwnershipPrivilege
#  in the process token, which PowerShell does not do on its own. That is why a
#  plain Set-Acl fails with "Requested registry access is not allowed" even from
#  an elevated prompt.
# ==============================================================================

$script:PrivilegesReady = $false

function Initialize-Privileges {
    if ($script:PrivilegesReady) { return $true }

    $source = @'
using System;
using System.Runtime.InteropServices;

public class PrivHelper {
    [DllImport("advapi32.dll", SetLastError=true)]
    internal static extern bool OpenProcessToken(IntPtr h, int acc, ref IntPtr phtok);
    [DllImport("advapi32.dll", SetLastError=true)]
    internal static extern bool LookupPrivilegeValue(string host, string name, ref long pluid);
    [DllImport("advapi32.dll", ExactSpelling=true, SetLastError=true)]
    internal static extern bool AdjustTokenPrivileges(IntPtr htok, bool disall,
        ref TokPriv1Luid newst, int len, IntPtr prev, IntPtr relen);
    [DllImport("kernel32.dll", ExactSpelling=true)]
    internal static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", ExactSpelling=true, SetLastError=true)]
    internal static extern bool CloseHandle(IntPtr hObject);

    [StructLayout(LayoutKind.Sequential, Pack=1)]
    internal struct TokPriv1Luid { public int Count; public long Luid; public int Attr; }

    public static bool Enable(string privilege) {
        IntPtr htok = IntPtr.Zero;
        TokPriv1Luid tp;
        if (!OpenProcessToken(GetCurrentProcess(), 0x20 | 0x8, ref htok)) return false;
        try {
            tp.Count = 1; tp.Luid = 0; tp.Attr = 0x00000002;
            if (!LookupPrivilegeValue(null, privilege, ref tp.Luid)) return false;
            if (!AdjustTokenPrivileges(htok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) return false;
            return Marshal.GetLastWin32Error() == 0;
        } finally { CloseHandle(htok); }
    }
}
'@

    try {
        if (-not ([System.Management.Automation.PSTypeName]'PrivHelper').Type) {
            Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
        }
    } catch {
        Write-Line (T 'priv.loadFailed') 'Yellow'
        return $false
    }

    $allEnabled = $true
    foreach ($privilege in @('SeTakeOwnershipPrivilege', 'SeRestorePrivilege',
                             'SeBackupPrivilege', 'SeSecurityPrivilege')) {
        if (-not [PrivHelper]::Enable($privilege)) { $allEnabled = $false }
    }

    $script:PrivilegesReady = $true
    return $allEnabled
}

function ConvertTo-SubKeyPath {
    # "HKLM:\SOFTWARE\..."  ->  "SOFTWARE\..."
    param([string]$PsPath)
    return ($PsPath -replace '^HKLM:\\', '')
}

function Get-KeyOwner {
    param([string]$PsPath)
    try {
        $subKeyPath = ConvertTo-SubKeyPath $PsPath
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
                   $subKeyPath,
                   [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadSubTree,
                   [System.Security.AccessControl.RegistryRights]::ReadPermissions)
        if (-not $key) { return $null }
        try {
            $acl = $key.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Owner)
            return $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
        } finally { $key.Close() }
    } catch { return $null }
}

function Set-KeyOwner {
    <#
        Takes ownership of a registry key for the Administrators group (or for
        the SID provided). Required before permissions can be modified.
    #>
    param([string]$PsPath, [string]$TargetSid = $script:AdminsSid)

    [void](Initialize-Privileges)

    $subKeyPath = ConvertTo-SubKeyPath $PsPath
    $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
               $subKeyPath,
               [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
               [System.Security.AccessControl.RegistryRights]::TakeOwnership)
    if (-not $key) { throw 'could not open the key to take ownership' }
    try {
        $acl = $key.GetAccessControl([System.Security.AccessControl.AccessControlSections]::None)
        $acl.SetOwner((New-Object System.Security.Principal.SecurityIdentifier($TargetSid)))
        $key.SetAccessControl($acl)
    } finally { $key.Close() }
}

function Edit-KeyAcl {
    <#
        Opens the key with permission-change rights and runs the supplied script
        block against its ACL object. Takes ownership first when needed.
    #>
    param(
        [string]$PsPath,
        [scriptblock]$Action
    )

    [void](Initialize-Privileges)
    $subKeyPath = ConvertTo-SubKeyPath $PsPath

    $openKey = {
        [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $subKeyPath,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::ChangePermissions -bor
            [System.Security.AccessControl.RegistryRights]::ReadPermissions)
    }

    $key = $null
    try { $key = & $openKey } catch { $key = $null }

    if (-not $key) {
        # no WRITE_DAC: take ownership and retry
        Set-KeyOwner -PsPath $PsPath
        $key = & $openKey
    }

    if (-not $key) { throw 'access denied even after taking ownership' }

    try {
        $acl = $key.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
        & $Action $acl
        $key.SetAccessControl($acl)
    } finally { $key.Close() }
}

function Get-KeyAclSafe {
    param([string]$PsPath)
    try {
        $subKeyPath = ConvertTo-SubKeyPath $PsPath
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
                   $subKeyPath,
                   [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadSubTree,
                   [System.Security.AccessControl.RegistryRights]::ReadPermissions)
        if (-not $key) { return $null }
        try { return $key.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access) }
        finally { $key.Close() }
    } catch { return $null }
}

function Save-OriginalOwner {
    param([string]$PsPath, [string]$Sid)
    if (-not $Sid) { return }
    if (-not (Test-Path $script:BackupFolder)) {
        New-Item -ItemType Directory -Path $script:BackupFolder -Force | Out-Null
    }
    $file = Join-Path $script:BackupFolder 'original_owners.txt'
    $line = "$PsPath|$Sid"
    $existing = @()
    if (Test-Path $file) { $existing = Get-Content $file }
    if ($existing -notcontains $line) { Add-Content -Path $file -Value $line }
}

function Get-SavedOriginalOwner {
    param([string]$PsPath)
    $file = Join-Path $script:BackupFolder 'original_owners.txt'
    if (-not (Test-Path $file)) { return $null }
    foreach ($line in Get-Content $file) {
        $parts = $line -split '\|', 2
        if ($parts[0] -eq $PsPath) { return $parts[1] }
    }
    return $null
}

# ==============================================================================
#  SERVICE DETECTION
# ==============================================================================

function Find-RealtekService {
    <#
        Locates the Realtek audio service without relying on an exact name,
        which varies between driver versions (RtkAudUService,
        RtkAudioUniversalService, ...).
    #>
    $candidates = @()

    try { $services = Get-CimInstance Win32_Service -ErrorAction Stop }
    catch { return $null }

    foreach ($service in $services) {
        $haystack = "$($service.PathName) $($service.Name) $($service.DisplayName)"
        if ($haystack -match $script:RealtekPattern -and $haystack -match 'aud') {
            $candidates += $service
        }
    }

    if ($candidates.Count -eq 0) { return $null }

    $preferred = $candidates | Where-Object { $_.PathName -match 'RtkAudUService' } | Select-Object -First 1
    if ($preferred) { return $preferred }

    return ($candidates | Select-Object -First 1)
}

# ==============================================================================
#  CLSID OWNERSHIP
# ==============================================================================

$script:ClsidCache = @{}

function Get-ClsidOwner {
    <#
        Determines who owns an APO CLSID by looking up the DLL it registers.
        This avoids depending on a hard-coded GUID list, which changes with
        driver versions and differs between machines.

        Returns: 'Realtek', 'THX', 'Dolby', ... or 'Unknown'
    #>
    param([string]$Clsid)

    if ([string]::IsNullOrWhiteSpace($Clsid)) { return 'Unknown' }
    $Clsid = $Clsid.Trim()
    if ($script:ClsidCache.ContainsKey($Clsid)) { return $script:ClsidCache[$Clsid] }

    $owner = 'Unknown'
    $dllPath = $null

    foreach ($root in @('HKLM:\SOFTWARE\Classes\CLSID',
                        'HKLM:\SOFTWARE\Classes\WOW6432Node\CLSID')) {
        $path = Join-Path $root "$Clsid\InprocServer32"
        if (Test-Path $path) {
            try { $dllPath = (Get-ItemProperty -Path $path -ErrorAction Stop).'(default)' }
            catch { $dllPath = $null }
            if ($dllPath) { break }
        }
    }

    if ($dllPath) {
        switch -Regex ($dllPath) {
            'rtk|realtek'     { $owner = 'Realtek'     ; break }
            'thx'             { $owner = 'THX'         ; break }
            'dolby|dax'       { $owner = 'Dolby'       ; break }
            'nahimic'         { $owner = 'Nahimic'     ; break }
            'sonic|creative'  { $owner = 'Creative'    ; break }
            'waves|maxxaudio' { $owner = 'Waves'       ; break }
            'razer'           { $owner = 'Razer'       ; break }
            'sennheiser'      { $owner = 'Sennheiser'  ; break }
            'steelseries'     { $owner = 'SteelSeries' ; break }
            'logi'            { $owner = 'Logitech'    ; break }
            default           { $owner = 'Other' }
        }
    }

    $script:ClsidCache[$Clsid] = $owner
    return $owner
}

function Get-ClsidList {
    param($Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) { return @($Value) }
    return @($Value | Where-Object { $_ -and $_.Trim() -ne '' })
}

# ==============================================================================
#  ENDPOINT ENUMERATION
# ==============================================================================

function Get-AudioEndpoints {
    <#
        Lists every audio endpoint with its friendly name, state and the status
        of its effects chain (clean or contaminated by Realtek).
    #>
    $result = @()

    foreach ($kind in $script:MMDeviceRoots.Keys) {
        $root = $script:MMDeviceRoots[$kind]
        if (-not (Test-Path $root)) { continue }

        foreach ($endpointKey in (Get-ChildItem $root -ErrorAction SilentlyContinue)) {
            $guid          = $endpointKey.PSChildName
            $propertiesKey = Join-Path $endpointKey.PSPath 'Properties'
            $properties    = if (Test-Path $propertiesKey) {
                                 Get-ItemProperty -Path $propertiesKey -ErrorAction SilentlyContinue
                             } else { $null }

            $name = $null
            if ($properties) {
                $name = $properties.$($script:PropFriendly)
                if (-not $name) { $name = $properties.$($script:PropDescription) }
            }
            if (-not $name) { $name = '(unnamed)' }

            $devicePath = if ($properties) { $properties.$($script:PropDevicePath) } else { $null }
            $state      = (Get-ItemProperty -Path $endpointKey.PSPath -ErrorAction SilentlyContinue).DeviceState

            $regPath = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$kind\$guid"
            $psPath  = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$kind\$guid"
            $fxPath  = "$psPath\FxProperties"

            $chain      = [ordered]@{}
            $hasRealtek = $false

            if (Test-Path $fxPath) {
                $fx = Get-ItemProperty -Path $fxPath -ErrorAction SilentlyContinue
                foreach ($property in $script:FxPropertyLabels.Keys) {
                    $clsids = Get-ClsidList $fx.$property
                    $owners = @()
                    foreach ($clsid in $clsids) {
                        $owner = Get-ClsidOwner $clsid
                        $owners += $owner
                        if ($owner -eq 'Realtek') { $hasRealtek = $true }
                    }
                    $chain[$property] = [pscustomobject]@{
                        LabelKey = $script:FxPropertyLabels[$property]
                        Clsids   = $clsids
                        Owners   = $owners
                    }
                }
            }

            # Is this an actual Realtek device? VEN_10EC is Realtek's vendor ID.
            $isRealtekNative = ($devicePath -match 'VEN_10EC' -or $devicePath -match 'HDAUDIO.*10EC')

            $result += [pscustomobject]@{
                Kind            = $kind
                Guid            = $guid
                Name            = $name
                DevicePath      = $devicePath
                State           = $state
                IsActive        = ($state -eq 1)
                RegPath         = $regPath
                PsPath          = $psPath
                FxPath          = $fxPath
                HasFx           = (Test-Path $fxPath)
                Chain           = $chain
                HasRealtek      = $hasRealtek
                IsRealtekNative = $isRealtekNative
                IsContaminated  = ($hasRealtek -and -not $isRealtekNative)
            }
        }
    }

    return $result
}

function Get-DeviceHint {
    <#
        Extracts a short identifier from the device path so endpoints sharing a
        friendly name (several "Microphone" entries, for instance) can be told
        apart in the selection list.
    #>
    param($Endpoint)

    $devicePath = $Endpoint.DevicePath
    if (-not $devicePath) { return '' }

    # USB devices: vendor and product ID
    $match = [regex]::Match($devicePath, 'VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})')
    if ($match.Success) {
        $vid = $match.Groups[1].Value.ToUpper()
        $vendor = switch ($vid) {
            '1532' { 'Razer' }
            '046D' { 'Logitech' }
            '0B05' { 'ASUS' }
            '1038' { 'SteelSeries' }
            '045E' { 'Microsoft' }
            '0D8C' { 'C-Media' }
            '1B1C' { 'Corsair' }
            '1395' { 'Sennheiser' }
            '0951' { 'HyperX' }
            default { "VID_$vid" }
        }
        return "USB $vendor $($match.Groups[2].Value.ToUpper())"
    }

    # HD Audio devices: codec vendor
    $match = [regex]::Match($devicePath, 'VEN_([0-9A-Fa-f]{4})')
    if ($match.Success) {
        $ven = $match.Groups[1].Value.ToUpper()
        $vendor = switch ($ven) {
            '10EC' { 'Realtek' }
            '10DE' { 'NVIDIA' }
            '1002' { 'AMD' }
            '8086' { 'Intel' }
            default { "VEN_$ven" }
        }
        return "HDAudio $vendor"
    }

    if ($devicePath -match 'BTHENUM|Bluetooth') { return 'Bluetooth' }
    if ($devicePath -match 'SWD\\MMDEVAPI')     { return 'virtual' }

    return ''
}

function Show-Endpoints {
    param([array]$Endpoints, [switch]$ActiveOnly)

    $shown = 0
    foreach ($endpoint in $Endpoints) {
        if ($ActiveOnly -and -not $endpoint.IsActive) { continue }
        $shown++

        $label = if ($endpoint.IsContaminated)      { T 'ep.contaminated' }
                 elseif ($endpoint.IsRealtekNative) { T 'ep.realtekNative' }
                 elseif ($endpoint.HasFx)           { T 'ep.ok' }
                 else                               { T 'ep.noFx' }

        $color = if ($endpoint.IsContaminated)      { 'Red' }
                 elseif ($endpoint.IsRealtekNative) { 'DarkGray' }
                 else                               { 'Green' }

        $stateText = if ($endpoint.IsActive) { T 'ep.active' }
                     else { T 'ep.inactive' @($endpoint.State) }

        Write-Host ("    {0,-8} " -f $endpoint.Kind) -NoNewline -ForegroundColor White
        Write-Host $endpoint.Name -NoNewline -ForegroundColor White
        Write-Host "  [$stateText]  " -NoNewline -ForegroundColor DarkGray
        Write-Host $label -ForegroundColor $color

        $hint = Get-DeviceHint -Endpoint $endpoint
        if ($hint) { Write-Line "        $hint" 'DarkCyan' }
    }

    if ($shown -eq 0) { Write-Line (T 'ep.noneFound') 'DarkGray' }
    return $shown
}

function Show-ChainDetail {
    param($Endpoint)

    if (-not $Endpoint.HasFx) {
        Write-Line (T 'diag.noFxChain') 'DarkGray'
        return
    }

    foreach ($property in $Endpoint.Chain.Keys) {
        $item  = $Endpoint.Chain[$property]
        $label = T $item.LabelKey

        if ($item.Clsids.Count -eq 0) {
            Write-Line ("    {0,-12} : {1}" -f $label, (T 'common.empty')) 'DarkGray'
            continue
        }

        $text  = ($item.Owners -join ' + ')
        $color = if ($item.Owners -contains 'Realtek') { 'Red' } else { 'Green' }
        Write-Host ("    {0,-12} : " -f $label) -NoNewline -ForegroundColor Gray
        Write-Host $text -ForegroundColor $color
    }
}

# ==============================================================================
#  BACKUP
# ==============================================================================

function Backup-Endpoint {
    param($Endpoint)

    if (-not (Test-Path $script:BackupFolder)) {
        New-Item -ItemType Directory -Path $script:BackupFolder -Force | Out-Null
    }

    $stamp    = Get-Date -Format 'yyyyMMdd_HHmmss'
    $safeName = ($Endpoint.Name -replace '[^\w\-]', '_')
    $file     = Join-Path $script:BackupFolder "$($Endpoint.Kind)_${safeName}_$stamp.reg"

    $output = & reg.exe export $Endpoint.RegPath $file /y 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Line (T 'backup.saved' @($file)) 'DarkGreen'
        return $true
    }
    Write-Line (T 'backup.failed' @($output)) 'Red'
    return $false
}

# ==============================================================================
#  CLEANUP
# ==============================================================================

function Invoke-EndpointCleanup {
    <#
        Removes only the Realtek-owned CLSIDs from the effects chain, keeping
        THX / Dolby / etc. Properties are emptied rather than deleted, which
        keeps the value present for the audio stack.
    #>
    param($Endpoint)

    if (-not $Endpoint.HasFx) {
        Write-Line (T 'clean.nothingToDo') 'DarkGray'
        return $false
    }

    $changed = $false

    foreach ($property in $Endpoint.Chain.Keys) {
        $item  = $Endpoint.Chain[$property]
        $label = T $item.LabelKey
        if ($item.Clsids.Count -eq 0) { continue }

        $kept = @()
        for ($i = 0; $i -lt $item.Clsids.Count; $i++) {
            if ($item.Owners[$i] -ne 'Realtek') { $kept += $item.Clsids[$i] }
        }

        # nothing from Realtek in this property
        if ($kept.Count -eq $item.Clsids.Count) { continue }

        try {
            Set-ItemProperty -Path $Endpoint.FxPath -Name $property `
                             -Value ([string[]]$kept) -Type MultiString

            $before = ($item.Owners -join '+')
            $after  = if ($kept.Count -eq 0) { T 'common.empty' }
                      else { (($item.Owners | Where-Object { $_ -ne 'Realtek' }) -join '+') }

            Write-Line ("    {0,-12} : {1}  ->  {2}" -f $label, $before, $after) 'Green'
            $changed = $true
        } catch {
            Write-Line (T 'common.error' @("$label - $($_.Exception.Message)")) 'Red'
        }
    }

    # CAPX subkey created by the service
    $capxPath = Join-Path $Endpoint.FxPath $script:CapxSubKey
    if (Test-Path $capxPath) {
        if (Confirm-Action (T 'clean.capxAsk') -DefaultNo) {
            try {
                Remove-Item -Path $capxPath -Recurse -Force
                Write-Line (T 'clean.capxRemoved') 'Green'
                $changed = $true
            } catch {
                Write-Line (T 'common.error' @($_.Exception.Message)) 'Red'
            }
        }
    }

    if (-not $changed) { Write-Line (T 'clean.nothingHere') 'DarkGray' }
    return $changed
}

# ==============================================================================
#  SERVICE SID AND BLOCKING
# ==============================================================================

function Enable-ServiceSid {
    param([string]$ServiceName)

    $current = (& sc.exe qsidtype $ServiceName 2>&1) -join ' '
    if ($current -match 'UNRESTRICTED|RESTRICTED') {
        Write-Line (T 'block.sidAlready' @(($current -replace '\s+', ' ').Trim())) 'DarkGreen'
        return $true
    }

    $output = & sc.exe sidtype $ServiceName unrestricted 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Line (T 'block.sidEnabled') 'Green'
        return $true
    }
    Write-Line (T 'block.sidFailed' @($output)) 'Red'
    return $false
}

function Set-EndpointBlock {
    param($Endpoint, [string]$ServiceName)

    # If FxProperties does not exist yet, protect the endpoint itself with
    # inheritance so the rule applies once the subkey is created.
    $target = if ($Endpoint.HasFx) { $Endpoint.FxPath } else { $Endpoint.PsPath }
    if (-not $Endpoint.HasFx) { Write-Line (T 'block.noFxInherit') 'Yellow' }

    # Record the original owner so it can be restored on revert.
    $originalOwner = Get-KeyOwner -PsPath $target
    if ($originalOwner) {
        Save-OriginalOwner -PsPath $target -Sid $originalOwner
        try {
            $ownerName = (New-Object System.Security.Principal.SecurityIdentifier($originalOwner)
                         ).Translate([System.Security.Principal.NTAccount]).Value
        } catch { $ownerName = $originalOwner }
        Write-Line (T 'block.currentOwner' @($ownerName)) 'DarkGray'
    }

    try {
        $serviceName = $ServiceName
        $applyRule = {
            param($acl)

            # drop any previous Deny for the same service to avoid duplicates
            $previous = @($acl.Access | Where-Object {
                $_.IdentityReference.Value -like "*$serviceName*" -and
                $_.AccessControlType -eq 'Deny'
            })
            foreach ($rule in $previous) { [void]$acl.RemoveAccessRule($rule) }

            $denyRule = New-Object System.Security.AccessControl.RegistryAccessRule(
                "NT SERVICE\$serviceName",
                'SetValue,CreateSubKey,Delete',
                'ContainerInherit,ObjectInherit',
                'None',
                'Deny')
            $acl.AddAccessRule($denyRule)
        }.GetNewClosure()

        Edit-KeyAcl -PsPath $target -Action $applyRule

        Write-Line (T 'block.applied' @($target)) 'Green'
        return $true

    } catch {
        Write-Line (T 'common.error' @($_.Exception.Message)) 'Red'
        Write-Line (T 'block.errAdmin') 'Yellow'
        Write-Line (T 'block.errAv1') 'Yellow'
        Write-Line (T 'block.errAv2') 'Yellow'
        return $false
    }
}

function Remove-EndpointBlock {
    param($Endpoint, [string]$ServiceName, [switch]$RestoreOwner)

    $removed = $false

    foreach ($target in @($Endpoint.FxPath, $Endpoint.PsPath)) {
        if (-not (Test-Path $target)) { continue }

        $acl = Get-KeyAclSafe -PsPath $target
        if (-not $acl) { continue }

        $existing = @($acl.Access | Where-Object {
            $_.IdentityReference.Value -like "*$ServiceName*" -and $_.AccessControlType -eq 'Deny'
        })
        if ($existing.Count -eq 0) { continue }

        try {
            $serviceName = $ServiceName
            $removeRule = {
                param($currentAcl)
                $rules = @($currentAcl.Access | Where-Object {
                    $_.IdentityReference.Value -like "*$serviceName*" -and
                    $_.AccessControlType -eq 'Deny'
                })
                foreach ($rule in $rules) { [void]$currentAcl.RemoveAccessRule($rule) }
            }.GetNewClosure()

            Edit-KeyAcl -PsPath $target -Action $removeRule

            Write-Line (T 'revert.removed' @($target)) 'Green'
            $removed = $true

            if ($RestoreOwner) {
                $originalSid = Get-SavedOriginalOwner -PsPath $target
                if ($originalSid) {
                    try {
                        Set-KeyOwner -PsPath $target -TargetSid $originalSid
                        Write-Line (T 'revert.ownerRestored') 'DarkGreen'
                    } catch {
                        Write-Line (T 'revert.ownerFailed') 'Yellow'
                    }
                }
            }
        } catch {
            Write-Line (T 'common.error' @($_.Exception.Message)) 'Red'
        }
    }

    if (-not $removed) { Write-Line (T 'revert.notFoundHere') 'DarkGray' }
    return $removed
}

function Get-BlockStatus {
    param($Endpoint, [string]$ServiceName)

    foreach ($target in @($Endpoint.FxPath, $Endpoint.PsPath)) {
        if (-not (Test-Path $target)) { continue }
        $acl = Get-KeyAclSafe -PsPath $target
        if (-not $acl) { continue }
        $found = @($acl.Access | Where-Object {
            $_.IdentityReference.Value -like "*$ServiceName*" -and $_.AccessControlType -eq 'Deny'
        })
        if ($found.Count -gt 0) { return $true }
    }
    return $false
}

# ==============================================================================
#  SELECTION
# ==============================================================================

function Select-Endpoints {
    param([array]$Endpoints, [string]$TitleKey = 'sel.titleProtect')

    $candidates = @($Endpoints | Where-Object { -not $_.IsRealtekNative -and $_.IsActive })

    if ($candidates.Count -eq 0) {
        Write-Line (T 'sel.noCandidates') 'Yellow'
        return @()
    }

    Write-Section (T $TitleKey)

    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $endpoint = $candidates[$i]
        $hint     = Get-DeviceHint -Endpoint $endpoint
        $flag     = if ($endpoint.IsContaminated) { ' <- ' + (T 'ep.contaminated') } else { '' }
        $color    = if ($endpoint.IsContaminated) { 'Red' } else { 'White' }

        Write-Host ("[{0}] {1,-8} {2,-22}" -f ($i + 1), $endpoint.Kind, $endpoint.Name) `
                   -NoNewline -ForegroundColor $color
        Write-Host ("{0,-20}" -f $hint) -NoNewline -ForegroundColor DarkCyan
        Write-Host $flag -ForegroundColor Red
    }

    Write-Line ''
    Write-Line (T 'sel.hintNumbers') 'DarkGray'
    Write-Line (T 'sel.hintKeys') 'DarkGray'
    $answer = Read-Host (T 'sel.choose')

    if ($answer -match '^[Cc]')   { return @() }
    if ($answer -match '^[AaTt]') { return $candidates }   # A = all / T = todos

    if ([string]::IsNullOrWhiteSpace($answer)) {
        $contaminated = @($candidates | Where-Object { $_.IsContaminated })
        if ($contaminated.Count -eq 0) { Write-Line (T 'sel.noneContaminated') 'Yellow' }
        return $contaminated
    }

    $selected = @()
    foreach ($token in ($answer -split ',')) {
        $token = $token.Trim()
        if ($token -match '^\d+$') {
            $index = [int]$token - 1
            if ($index -ge 0 -and $index -lt $candidates.Count) { $selected += $candidates[$index] }
        }
    }
    return $selected
}

# ==============================================================================
#  ACTIONS
# ==============================================================================

function Invoke-Diagnosis {
    param($Service)

    Write-Header (T 'diag.title')

    Write-Section (T 'diag.serviceSection')
    if ($Service) {
        Write-Line (T 'diag.serviceName'    @($Service.Name)) 'White'
        Write-Line (T 'diag.serviceDisplay' @($Service.DisplayName)) 'Gray'
        Write-Line (T 'diag.serviceState'   @($Service.State, $Service.StartMode)) 'Gray'
        $sid = ((& sc.exe qsidtype $Service.Name 2>&1) -join ' ') -replace '\s+', ' '
        Write-Line (T 'diag.serviceSid' @($sid.Trim())) 'Gray'
    } else {
        Write-Line (T 'diag.serviceMissing') 'Yellow'
        Write-Line (T 'diag.serviceMissingWhy') 'DarkGray'
    }

    $endpoints = Get-AudioEndpoints

    Write-Section (T 'diag.endpointsSection')
    [void](Show-Endpoints -Endpoints $endpoints -ActiveOnly)

    $contaminated = @($endpoints | Where-Object { $_.IsContaminated })

    Write-Section (T 'diag.resultSection')
    if ($contaminated.Count -eq 0) {
        Write-Line (T 'diag.resultClean') 'Green'
    } else {
        Write-Line (T 'diag.resultDirty' @($contaminated.Count)) 'Red'
        foreach ($endpoint in $contaminated) {
            Write-Line ''
            Write-Line "    >> $($endpoint.Kind) - $($endpoint.Name)" 'White'
            Show-ChainDetail -Endpoint $endpoint
            if ($Service) {
                $blocked = Get-BlockStatus -Endpoint $endpoint -ServiceName $Service.Name
                $text    = if ($blocked) { T 'diag.blockYes' } else { T 'diag.blockNo' }
                $color   = if ($blocked) { 'Green' } else { 'DarkGray' }
                Write-Host (T 'diag.blockActive') -NoNewline -ForegroundColor Gray
                Write-Host $text -ForegroundColor $color
            }
        }
    }

    if ($Service) {
        $protected = @($endpoints | Where-Object {
            -not $_.IsRealtekNative -and $_.IsActive -and
            (Get-BlockStatus -Endpoint $_ -ServiceName $Service.Name)
        })
        if ($protected.Count -gt 0) {
            Write-Section (T 'diag.protectedSection')
            foreach ($endpoint in $protected) {
                $status = if ($endpoint.IsContaminated) { T 'diag.protectedDirty' }
                          else { T 'diag.protectedClean' }
                $color  = if ($endpoint.IsContaminated) { 'Yellow' } else { 'Green' }
                Write-Host ("    {0,-8} {1,-28} " -f $endpoint.Kind, $endpoint.Name) `
                           -NoNewline -ForegroundColor Gray
                Write-Host $status -ForegroundColor $color
            }
        }
    }

    Wait-Menu
}

function Invoke-Cleanup {
    Write-Header (T 'clean.title')

    Write-Line (T 'clean.intro1') 'Gray'
    Write-Line (T 'clean.intro2') 'Gray'

    $endpoints = Get-AudioEndpoints
    $selected  = Select-Endpoints -Endpoints $endpoints -TitleKey 'sel.titleClean'

    if ($selected.Count -eq 0) {
        Write-Line (T 'common.nothingSelected') 'Yellow'; Wait-Menu; return
    }

    Write-Line ''
    if (-not (Confirm-Action (T 'clean.confirm' @($selected.Count)))) {
        Write-Line (T 'common.cancelled') 'Yellow'; Wait-Menu; return
    }

    foreach ($endpoint in $selected) {
        Write-Line ''
        Write-Line ">> $($endpoint.Kind) - $($endpoint.Name)" 'White'
        if (-not (Backup-Endpoint -Endpoint $endpoint)) {
            Write-Line (T 'backup.skipDevice') 'Red'
            continue
        }
        [void](Invoke-EndpointCleanup -Endpoint $endpoint)
    }

    Write-Line ''
    Write-Line (T 'clean.restartHint') 'Gray'
    Write-Line '    Restart-Service Audiosrv -Force' 'DarkGray'
    Write-Line ''
    Write-Line (T 'clean.warnReturns') 'Yellow'

    Wait-Menu
}

function Invoke-Block {
    param($Service)

    Write-Header (T 'block.title')

    if (-not $Service) {
        Write-Line (T 'block.serviceMissing') 'Yellow'
        Wait-Menu; return
    }

    Write-Line (T 'block.howTitle') 'White'
    Write-Line (T 'block.how1')  'Gray'
    Write-Line (T 'block.how1b') 'Gray'
    Write-Line (T 'block.how2')  'Gray'
    Write-Line (T 'block.how2b') 'Gray'
    Write-Line ''
    Write-Line (T 'block.notTitle') 'White'
    Write-Line (T 'block.not1') 'Gray'
    Write-Line (T 'block.not2') 'Gray'
    Write-Line (T 'block.not3') 'Gray'

    $endpoints = Get-AudioEndpoints
    $selected  = Select-Endpoints -Endpoints $endpoints -TitleKey 'sel.titleProtect'

    if ($selected.Count -eq 0) {
        Write-Line (T 'common.nothingSelected') 'Yellow'; Wait-Menu; return
    }

    Write-Line ''
    if (-not (Confirm-Action (T 'block.confirm' @($selected.Count)))) {
        Write-Line (T 'common.cancelled') 'Yellow'; Wait-Menu; return
    }

    Write-Line ''
    Write-Section (T 'block.stopSection')
    try {
        $serviceState = Get-Service -Name $Service.Name
        if ($serviceState.Status -ne 'Stopped') {
            Stop-Service -Name $Service.Name -Force
            Start-Sleep -Seconds 2
            Write-Line (T 'block.stopped') 'Green'
        } else {
            Write-Line (T 'block.alreadyStopped') 'DarkGreen'
        }
    } catch {
        Write-Line (T 'common.warning' @($_.Exception.Message)) 'Yellow'
    }

    Write-Section (T 'block.sidSection')
    if (-not (Enable-ServiceSid -ServiceName $Service.Name)) {
        Write-Line (T 'block.sidAbort') 'Red'
        Wait-Menu; return
    }

    Write-Section (T 'block.applySection')
    foreach ($endpoint in $selected) {
        Write-Line ''
        Write-Line ">> $($endpoint.Kind) - $($endpoint.Name)" 'White'

        if (-not (Backup-Endpoint -Endpoint $endpoint)) {
            Write-Line (T 'backup.skipDevice') 'Red'
            continue
        }
        if ($endpoint.IsContaminated) { [void](Invoke-EndpointCleanup -Endpoint $endpoint) }
        [void](Set-EndpointBlock -Endpoint $endpoint -ServiceName $Service.Name)
    }

    Write-Section (T 'block.nextSection')
    Write-Line (T 'block.next1') 'White'
    Write-Line "      Set-Service -Name $($Service.Name) -StartupType Automatic" 'DarkGray'
    Write-Line ''
    Write-Line (T 'block.next2')  'White'
    Write-Line (T 'block.next2b') 'Gray'
    Write-Line (T 'block.next2c') 'Gray'
    Write-Line ''
    Write-Line (T 'block.next3') 'White'
    Write-Line ''
    Write-Line (T 'block.fallback1') 'Yellow'
    Write-Line (T 'block.fallback2') 'Yellow'
    Write-Line (T 'block.fallback3') 'Yellow'

    Wait-Menu
}

function Invoke-Revert {
    param($Service)

    Write-Header (T 'revert.title')

    if (-not $Service) {
        Write-Line (T 'svc.notFound') 'Yellow'
        Wait-Menu; return
    }

    $endpoints = Get-AudioEndpoints
    $blocked   = @($endpoints | Where-Object {
        Get-BlockStatus -Endpoint $_ -ServiceName $Service.Name
    })

    if ($blocked.Count -eq 0) {
        Write-Line (T 'revert.none') 'Yellow'
        Wait-Menu; return
    }

    Write-Section (T 'revert.section')
    foreach ($endpoint in $blocked) {
        $hint = Get-DeviceHint -Endpoint $endpoint
        Write-Host ("    {0,-8} {1,-26}" -f $endpoint.Kind, $endpoint.Name) `
                   -NoNewline -ForegroundColor White
        Write-Host $hint -ForegroundColor DarkCyan
    }

    Write-Line ''
    if (-not (Confirm-Action (T 'revert.confirm') -DefaultNo)) {
        Write-Line (T 'common.cancelled') 'Yellow'; Wait-Menu; return
    }

    foreach ($endpoint in $blocked) {
        Write-Line ''
        Write-Line ">> $($endpoint.Kind) - $($endpoint.Name)" 'White'
        [void](Remove-EndpointBlock -Endpoint $endpoint -ServiceName $Service.Name -RestoreOwner)
    }

    Write-Line ''
    Write-Line (T 'revert.sidNote') 'Gray'
    Write-Line (T 'revert.sidDisable' @($Service.Name)) 'DarkGray'

    Wait-Menu
}

function Invoke-ServiceControl {
    param($Service)

    Write-Header (T 'svc.title')

    if (-not $Service) {
        Write-Line (T 'svc.notFound') 'Yellow'
        Wait-Menu; return
    }

    # Re-read the live state; the cached object is from startup.
    try { $live = Get-Service -Name $Service.Name -ErrorAction Stop } catch { $live = $null }
    $state     = if ($live) { $live.Status } else { $Service.State }
    $startMode = (Get-CimInstance Win32_Service -Filter "Name='$($Service.Name)'" -ErrorAction SilentlyContinue).StartMode
    if (-not $startMode) { $startMode = $Service.StartMode }

    Write-Line (T 'svc.name'    @($Service.Name)) 'White'
    Write-Line (T 'svc.state'   @($state)) 'Gray'
    Write-Line (T 'svc.startup' @($startMode)) 'Gray'

    Write-Line ''
    Write-Line (T 'svc.warn1') 'Yellow'
    Write-Line (T 'svc.warn2') 'Yellow'
    Write-Line (T 'svc.warn3') 'Green'

    Write-Line ''
    Write-Line (T 'svc.opt1') 'White'
    Write-Line (T 'svc.opt2') 'White'
    Write-Line (T 'svc.opt3') 'White'
    Write-Line (T 'svc.opt0') 'DarkGray'
    Write-Line ''

    $choice = Read-Host (T 'common.option')

    try {
        switch ($choice) {
            '1' {
                Stop-Service -Name $Service.Name -Force -ErrorAction SilentlyContinue
                Set-Service  -Name $Service.Name -StartupType Disabled
                Write-Line ''
                Write-Line (T 'svc.doneDisabled') 'Green'
            }
            '2' {
                Set-Service   -Name $Service.Name -StartupType Automatic
                Start-Service -Name $Service.Name -ErrorAction SilentlyContinue
                Write-Line ''
                Write-Line (T 'svc.doneEnabled') 'Green'
            }
            '3' {
                Stop-Service -Name $Service.Name -Force
                Write-Line ''
                Write-Line (T 'svc.doneStopped') 'Green'
            }
            default { Wait-Menu; return }
        }
    } catch {
        Write-Line (T 'common.error' @($_.Exception.Message)) 'Red'
    }

    Wait-Menu
}

function Show-Backups {
    Write-Header (T 'backup.title')

    if (-not (Test-Path $script:BackupFolder)) {
        Write-Line (T 'backup.noneYet') 'Yellow'
        Write-Line (T 'backup.expectedPath' @($script:BackupFolder)) 'DarkGray'
        Wait-Menu; return
    }

    $files = @(Get-ChildItem -Path $script:BackupFolder -Filter '*.reg' -ErrorAction SilentlyContinue |
               Sort-Object LastWriteTime -Descending)

    Write-Line (T 'backup.folder' @($script:BackupFolder)) 'Gray'
    Write-Line ''

    if ($files.Count -eq 0) {
        Write-Line (T 'backup.folderEmpty') 'Yellow'
    } else {
        foreach ($file in $files) {
            Write-Host ("    {0:yyyy-MM-dd HH:mm}  " -f $file.LastWriteTime) `
                       -NoNewline -ForegroundColor DarkGray
            Write-Host $file.Name -ForegroundColor White
        }

        Write-Line ''
        Write-Line (T 'backup.restoreHint') 'Gray'
        Write-Line ('    reg.exe import "' + (Join-Path $script:BackupFolder $files[0].Name) + '"') 'DarkGray'
        Write-Line ''
        Write-Line (T 'backup.restoreNote1') 'DarkGray'
        Write-Line (T 'backup.restoreNote2') 'DarkGray'
    }

    Wait-Menu
}

function Show-About {
    Write-Header (T 'about.title')

    Write-Line (T 'about.sympTitle') 'White'
    Write-Line (T 'about.symp1') 'Gray'
    Write-Line (T 'about.symp2') 'Gray'
    Write-Line (T 'about.symp3') 'Gray'

    Write-Line ''
    Write-Line (T 'about.causeTitle') 'White'
    Write-Line (T 'about.cause1') 'Gray'
    Write-Line (T 'about.cause2') 'Gray'
    Write-Line (T 'about.cause3') 'Gray'
    Write-Line (T 'about.cause4') 'Gray'
    Write-Line ''
    Write-Line (T 'about.regNote') 'Gray'
    Write-Line '    HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio' 'DarkCyan'
    Write-Line '         \Render|Capture\{endpoint}\FxProperties' 'DarkCyan'

    Write-Line ''
    Write-Line (T 'about.orderTitle') 'White'
    Write-Line (T 'about.order1') 'Gray'
    Write-Line (T 'about.order2') 'Gray'
    Write-Line (T 'about.order3') 'Gray'
    Write-Line (T 'about.order4') 'Gray'

    Write-Line ''
    Write-Line (T 'about.failTitle') 'White'
    Write-Line (T 'about.fail1') 'Gray'
    Write-Line (T 'about.fail2') 'Gray'
    Write-Line (T 'about.fail3') 'Gray'
    Write-Line (T 'about.fail4') 'Gray'
    Write-Line (T 'about.fail5') 'Gray'

    Write-Line ''
    Write-Line (T 'about.warnTitle') 'Yellow'
    Write-Line (T 'about.warn1') 'DarkYellow'
    Write-Line (T 'about.warn2') 'DarkYellow'

    Wait-Menu
}

# ==============================================================================
#  MENU
# ==============================================================================

function Get-Summary {
    <#
        Counts, for the menu header, how many endpoints are contaminated and
        how many already carry the block.
    #>
    param($Service)

    $endpoints    = Get-AudioEndpoints
    $contaminated = @($endpoints | Where-Object { $_.IsContaminated })

    $blocked = @()
    if ($Service) {
        $blocked = @($endpoints | Where-Object {
            -not $_.IsRealtekNative -and $_.IsActive -and
            (Get-BlockStatus -Endpoint $_ -ServiceName $Service.Name)
        })
    }

    return [pscustomobject]@{
        Contaminated = $contaminated.Count
        Blocked      = $blocked.Count
    }
}

function Show-Menu {
    param($Service, $Summary)

    Clear-Host
    Write-Host ''
    Write-Host ('#' * 61) -ForegroundColor DarkCyan
    Write-Host ('#' + (' ' * 59) + '#') -ForegroundColor DarkCyan
    Write-Host (T 'menu.banner') -ForegroundColor Cyan
    Write-Host ('#' + (' ' * 59) + '#') -ForegroundColor DarkCyan
    Write-Host ('#' * 61) -ForegroundColor DarkCyan
    Write-Host ''

    if ($Service) {
        Write-Host (T 'menu.service') -NoNewline -ForegroundColor Gray
        Write-Host "$($Service.Name) [$($Service.State)]" -ForegroundColor White
    } else {
        Write-Host (T 'menu.serviceNotFound') -ForegroundColor Yellow
    }

    Write-Host (T 'menu.contamination') -NoNewline -ForegroundColor Gray
    if ($Summary.Contaminated -eq 0) {
        Write-Host (T 'menu.contaminationNone') -ForegroundColor Green
    } else {
        Write-Host (T 'menu.contaminationSome' @($Summary.Contaminated)) -ForegroundColor Red
    }

    if ($Summary.Blocked -gt 0) {
        Write-Host (T 'menu.blocks') -NoNewline -ForegroundColor Gray
        Write-Host (T 'menu.blocksActive' @($Summary.Blocked)) -ForegroundColor Green
    }

    Write-Host ''
    Write-Host ('   ' + ('-' * 55)) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host (T 'menu.opt1') -ForegroundColor White
    Write-Host (T 'menu.opt2') -ForegroundColor White
    Write-Host (T 'menu.opt3') -ForegroundColor Green
    Write-Host (T 'menu.opt4') -ForegroundColor White
    Write-Host (T 'menu.opt5') -ForegroundColor White
    Write-Host (T 'menu.opt6') -ForegroundColor White
    Write-Host (T 'menu.opt7') -ForegroundColor White
    Write-Host (T 'menu.opt8') -ForegroundColor DarkCyan
    Write-Host (T 'menu.opt0') -ForegroundColor DarkGray
    Write-Host ''
    Write-Host ('   ' + ('-' * 55)) -ForegroundColor DarkGray
    Write-Host ''
}

function Select-Language {
    <#
        Asks for the interface language. The current value of $script:Language
        (guessed from the system culture) is offered as the default, so ENTER
        is enough.
    #>
    $default = if ($script:Language -eq 'pt') { '2' } else { '1' }

    Write-Host ''
    Write-Host ('=' * 61) -ForegroundColor DarkCyan
    Write-Host ('  ' + (T 'lang.prompt')) -ForegroundColor Cyan
    Write-Host ('=' * 61) -ForegroundColor DarkCyan
    Write-Host ''
    Write-Host ('  ' + (T 'lang.optionEn')) -ForegroundColor White
    Write-Host ('  ' + (T 'lang.optionPt')) -ForegroundColor White
    Write-Host ''

    $answer = Read-Host ((T 'lang.choice') + " [$default]")
    if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $default }

    $script:Language = if ($answer.Trim() -eq '2') { 'pt' } else { 'en' }
}

# ==============================================================================
#  ENTRY POINT
# ==============================================================================

# Language: explicit parameter wins; otherwise guess from the culture and ask.
if ($Language) {
    $script:Language = $Language
} else {
    $culture = ''
    try { $culture = (Get-Culture).Name } catch { }
    $script:Language = if ($culture -like 'pt*') { 'pt' } else { 'en' }
    Select-Language
}

if (-not (Test-Administrator)) {
    Write-Host ''
    Write-Host (T 'admin.required') -ForegroundColor Red
    Write-Host ''
    Write-Host (T 'admin.howTitle') -ForegroundColor Yellow
    Write-Host (T 'admin.how1') -ForegroundColor Gray
    Write-Host (T 'admin.how2') -ForegroundColor Gray
    Write-Host (T 'admin.how3') -ForegroundColor Gray
    Write-Host (T 'admin.how4') -ForegroundColor Gray
    Write-Host ''
    Write-Host (T 'admin.policyHint') -ForegroundColor Yellow
    Write-Host '    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass' -ForegroundColor DarkGray
    Write-Host ''
    exit 1
}

# Enable the token privileges needed to take ownership of TrustedInstaller keys.
[void](Initialize-Privileges)

Write-Host ''
Write-Host (T 'common.detecting') -ForegroundColor DarkGray

$service = Find-RealtekService

while ($true) {
    $summary = Get-Summary -Service $service
    Show-Menu -Service $service -Summary $summary

    $choice = Read-Host ('   ' + (T 'common.option'))

    switch ($choice.Trim()) {
        '1' { Invoke-Diagnosis      -Service $service }
        '2' { Invoke-Cleanup }
        '3' { Invoke-Block          -Service $service }
        '4' { Invoke-Revert         -Service $service }
        '5' {
              Invoke-ServiceControl -Service $service
              $service = Find-RealtekService   # state may have changed
            }
        '6' { Show-Backups }
        '7' { Show-About }
        '8' { $script:Language = if ($script:Language -eq 'pt') { 'en' } else { 'pt' } }
        '0' {
              Write-Host ''
              Write-Host (T 'common.bye') -ForegroundColor Cyan
              Write-Host ''
              exit 0
            }
        default { }
    }
}
