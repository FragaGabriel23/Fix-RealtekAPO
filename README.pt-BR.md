# Realtek APO Fix

**O serviço de áudio da Realtek injeta os APOs dele em endpoints de áudio que não são Realtek.**
Dois processadores de áudio passam a atuar sobre o mesmo fluxo, e o seu headset USB ou wireless
começa a perder ganho, estalar e se comportar como se houvesse falha de transmissão.

Este repositório traz uma ferramenta em PowerShell que encontra o problema, limpa e impede que
ele volte — sem desinstalar nada e sem perder THX, Dolby, Nahimic ou qualquer outro efeito
legítimo.

Interface disponível em **Português (Brasil)** e **English**.

---

## Sintomas

- Headset ou caixa de som USB/wireless com o ganho caindo e voltando sozinho
- Estalos, chiado, volume instável
- Controle de volume por aplicativo funcionando de forma errática
- O problema volta **a cada reinicialização**, mesmo depois de corrigir o registro na mão
- Desinstalar o software do headset "resolve" — ao custo de perder todos os recursos dele

Relatado no Razer BlackShark V2 Pro, mas o mecanismo não é específico de marca: qualquer
endpoint não-Realtek em uma máquina com codec Realtek pode ser afetado.

---

## Causa

O serviço de áudio da Realtek (`RtkAudUService64.exe`, registrado como `RtkAudUService` ou
`RtkAudioUniversalService` conforme a versão do driver) percorre os endpoints de áudio do
Windows e anexa os APOs da Realtek à cadeia de efeitos de dispositivos que não são Realtek.

A cadeia de efeitos fica em:

```
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\{Render|Capture}\{endpoint}\FxProperties
```

no conjunto de propriedades `{d04e05a6-594b-4fb6-a80d-01af5eed7d1d}`:

| Propriedade | Significado |
|---|---|
| `,13` | SFX — efeitos de stream |
| `,14` | MFX — efeitos de modo |
| `,19` | SFX offload |
| `,20` | MFX offload |

Uma captura do Process Monitor mostra o serviço lendo a cadeia existente e gravando de volta
com os CLSIDs dele anexados, **em menos de um milissegundo, sem nenhuma consulta a hardware ou
preset no meio**. Ele preserva o que já estava lá — que é exatamente o motivo de o THX continuar
aparecendo ao lado da Realtek:

```
,13   {C792E395-...}                      ->  {C792E395-...} , {905399BE-...}
,14   {68650828-...}                      ->  {68650828-...} , {9063CBD4-...}
,19   (ausente)                           ->  {90B31DF6-...}
,20   (ausente)                           ->  {90C35236-...}
```

Os CLSIDs `905399BE` / `9063CBD4` / `90B31DF6` / `90C35236` resolvem para `RtkIntU642.dll`
(`realtekuapo2.inf`) — são da Realtek, em um dispositivo que não é da Realtek.

Relato completo, incluindo as hipóteses testadas e descartadas:
[docs/INVESTIGACAO.pt-BR.md](docs/INVESTIGACAO.pt-BR.md).

---

## Como a correção funciona

O Windows pode dar a um serviço uma identidade própria — o **SID por serviço**, um recurso
oficialmente suportado:

```
sc.exe sidtype <NomeDoServico> unrestricted
```

O serviço passa a rodar como `NT SERVICE\<NomeDoServico>`, e essa identidade pode ser nomeada
em uma ACL. A ferramenta aplica uma regra **Deny** para `SetValue, CreateSubKey, Delete`
apenas a essa identidade, na chave `FxProperties` do endpoint que você escolher.

O resultado:

- O serviço da Realtek continua conseguindo **ler** a chave — nada trava, nada gera erro
- Ele não consegue mais **escrever** nela — a contaminação para na origem
- Synapse, THX, Dolby e qualquer outro aplicativo continuam configurando o dispositivo normalmente
- O áudio Realtek onboard mantém **todos** os efeitos
- O serviço permanece em **Automático**; nada é desativado ou desinstalado

As chaves de endpoint de áudio pertencem ao `TrustedInstaller`, então a ferramenta habilita o
privilégio `SeTakeOwnershipPrivilege` no próprio token do processo, assume a propriedade,
aplica a regra e registra o proprietário original para poder restaurá-lo na reversão.

---

## Como usar

1. Baixe o `Fix-RealtekAPO.ps1`
2. Abra o **PowerShell como Administrador**
3. Execute:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Fix-RealtekAPO.ps1
```

Para pular a pergunta de idioma:

```powershell
.\Fix-RealtekAPO.ps1 -Language pt     # Português (Brasil)
.\Fix-RealtekAPO.ps1 -Language en     # English
```

### Ordem recomendada

| Passo | Opção do menu |
|---|---|
| 1 | `[1] Diagnóstico` — confirma se o seu caso é este |
| 2 | `[3] Aplicar bloqueio` — faz backup, limpa, protege e oferece reiniciar o áudio do Windows para a correção valer na hora |
| 3 | **Reinicie** — o serviço roda no boot e em outros momentos de uso; é isso que prova que o bloqueio segura |
| 4 | `[1] Diagnóstico` — confirma que o endpoint continuou limpo |

### Menu

```
[1] Diagnóstico          ver o estado atual
[2] Limpar contaminação  remove os APOs Realtek indevidos
[3] Aplicar bloqueio     limpa + impede que volte
[4] Reverter bloqueio    desfaz a proteção
[5] Controlar o serviço  parar / desativar / reativar
[6] Backups              lista os backups gerados
[7] Sobre o problema     explicação e ordem recomendada
[8] Language             trocar de idioma
[9] Reiniciar o áudio    aplica alterações sem reiniciar o PC
[0] Sair
```

Nada é fixo no código: o nome do serviço é detectado varrendo os serviços instalados, os
endpoints são enumerados do registro, e cada CLSID da cadeia é resolvido até a DLL que o
registra — é assim que a ferramenta distingue um APO da Realtek de um do THX, Dolby, Nahimic,
Creative, Waves, Razer, Sennheiser, SteelSeries ou Logitech, em vez de depender de uma lista
de GUIDs conhecidos.

O diagnóstico lista cada CLSID da cadeia de efeitos com o fabricante e a DLL correspondente.
Se abrir uma issue, inclua essa saída — é ela que torna o relato útil.

---

## Segurança

- Um backup `.reg` do endpoint é exportado **antes** de qualquer alteração, em
  `Área de Trabalho\RealtekAPOFix_Backups`
- O proprietário original de cada chave alterada é salvo em `original_owners.txt`, na mesma pasta
- A limpeza **esvazia** as propriedades afetadas em vez de apagá-las, e remove somente os
  CLSIDs que resolvem para a Realtek — todo o resto da cadeia é preservado
- A opção `[4] Reverter bloqueio` remove a regra Deny e restaura o proprietário original
- Nada é desinstalado, e o serviço da Realtek só é desativado se você pedir explicitamente na
  opção `[5]`
- Quando uma chave é somente leitura para administradores, a ferramenta assume a
  propriedade e concede escrita ao grupo Administradores antes de limpar. O proprietário
  original é restaurado na reversão; a permissão de escrita permanece.
- Remover a subchave CAPX é opcional e cosmético: ela guarda apenas metadados e o serviço
  a recria a cada execução. É o bloqueio que mantém a cadeia limpa.

---

## Limitações

- **O GUID do endpoint muda quando você reinstala o Synapse** (ou qualquer software que recrie
  o dispositivo). O bloqueio está preso a esse GUID, então depois de uma reinstalação é preciso
  rodar a opção `[3]` novamente no endpoint novo.
- Se a contaminação voltar *mesmo com o bloqueio aplicado*, quem escreve não é este serviço e
  sim outro componente — provavelmente o próprio driver, via PnP. Nesse caso, a opção `[5]`
  (desativar o serviço) é a alternativa garantida. Ela não impede o áudio interno de funcionar;
  apenas remove os efeitos do Realtek Audio Console.
- Testado no Windows 10 e no Windows 11, x64.

---

## Aviso

Esta ferramenta altera permissões e valores do registro do Windows. Os backups são gerados
automaticamente, mas use por sua conta e risco. Não possui vínculo com a Realtek, a Razer, a
THX ou a Microsoft, nem conta com apoio delas.

---

## Licença

MIT — veja [LICENSE](LICENSE).

## Créditos

Investigado e construído por **FragaGabriel23**, a partir de capturas do Process Monitor e comparações de registro de uma máquina afetada.

English: [README.md](README.md)
