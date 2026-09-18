# Investigação

Como a causa foi encontrada, o que foi descartado no caminho e quais evidências sustentam a
conclusão. As hipóteses descartadas estão aqui de propósito: várias delas parecem convincentes
e se repetem em outros relatos deste problema.

---

## 1. Ponto de partida

Um Razer BlackShark V2 Pro (dongle USB `VID_1532` / `PID_0555`) começou a perder ganho e estalar
logo depois de uma reinstalação do Synapse e do THX Spatial Audio. O mesmo hardware, as mesmas
versões de driver e a mesma instalação do Windows vinham funcionando havia meses.

Comparando a exportação do registro do endpoint do headset com uma exportação sabidamente boa,
a cadeia de efeitos aparecia com dois fabricantes ao mesmo tempo:

```
{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},13  =  {C792E395-...} , {905399BE-...}
{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},14  =  {68650828-...} , {9063CBD4-...}
{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},19  =  {90B31DF6-...}
{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},20  =  {90C35236-...}
```

Resolvendo cada CLSID por `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render\{endpoint}\FxProperties`:

| CLSID | DLL | Fabricante |
|---|---|---|
| `{C792E395-BD30-472D-9A2F-2783D7FAF812}` | THX SFX | THX |
| `{68650828-CA0F-4196-9096-5F50931AF10A}` | THX MFX | THX |
| `{905399BE-697F-47A1-B8DA-169719603BCF}` | `RtkIntU642.dll` | Realtek |
| `{9063CBD4-3561-449D-8011-E21BBB69B9DB}` | `RtkIntU642.dll` | Realtek |
| `{90B31DF6-F3AB-4867-8E21-209237065312}` | `RtkIntU642.dll` | Realtek |
| `{90C35236-DBBD-420C-B63C-FDBFE465201A}` | `RtkIntU642.dll` | Realtek |

Remover as entradas da Realtek corrigia o áudio na hora. E voltava no boot seguinte.

---

## 2. Hipóteses testadas e descartadas

### H1 — O Synapse reescreve a cadeia na inicialização
**Descartada.** Uma captura do Process Monitor filtrada pelo caminho do registro mostrou as
escritas vindo do `RtkAudUService64.exe`, e não de nenhum processo da Razer.

### H2 — O store CAPX `Default` funciona como um modelo que repopula a cadeia
O endpoint tem um contexto CAPX, `{12325c6d-6d93-4ab3-bff6-d04968d361dd}`, com os stores
`Default`, `User` e `Volatile`. A Microsoft documenta o `Default` como o store que pode ser
repopulado a partir de um INF de driver, o que o tornava um suspeito natural.

**Descartada.** O `Default` foi esvaziado; a contaminação voltou no boot seguinte mesmo assim.
No processo ele caiu de dezenas de valores para nove, mas isso não mudou o resultado.

### H3 — A ausência de `{d86fe031-a04b-47e5-9b60-3df61dd0f181},0` faz o serviço cair no `Default`
**Descartada.** O valor foi criado manualmente; a contaminação voltou igual. A teoria já estava
fraca, porque o valor vizinho `,1` é incrementado pelo serviço em tempo de execução — ou seja,
são contadores que o serviço mantém, não entradas que ele lê para decidir alguma coisa.

### H4 — Um preset de elegibilidade em `ApoCondPreset` marca o endpoint como elegível
O serviço lê `HKLM\SOFTWARE\Realtek\Audio\RtkAudUService\ApoCondPreset\...\GenaricPresetId` na
mesma captura, o que se parece exatamente com uma consulta de política.

**Descartada pelos timestamps.** A leitura acontece *depois* das escritas, não antes:

| Captura | Escrita dos APOs | Leitura de `GenaricPresetId` |
|---|---|---|
| #1 | `20:41:37,422` | `20:41:37,515` |
| #2 | `21:43:09,922` | `21:43:10,012` |

O valor também foi renomeado na máquina para testar: a contaminação continuou. Esta é a
hipótese que mais vale destacar, porque é o tipo de correlação que se lê como causa em um log
de 45 mil linhas.

### H5 — O `netstate2_a_AE58_g` no store CAPX liga o endpoint ao preset Realtek/ASUS
**Descartada.** A varredura da árvore `MMDevices` inteira mostrou esse componente presente em
*todos* os endpoints da máquina, inclusive nos que nunca são contaminados. Não é específico do
dispositivo afetado e, portanto, não pode ser o que o distingue.

### H6 — O serviço acha que o headset é um dispositivo Realtek
**Descartada.** A captura mostra o serviço lendo os hardware IDs imediatamente antes e vendo
`USB\VID_1532&PID_0555`, com `usbaudio` como driver. Ele sabe exatamente o que o dispositivo é.
E aplica os APOs dele mesmo assim.

---

## 3. O teste que resolveu a questão

Executado na máquina afetada, nesta ordem:

1. Desinstalar Synapse, THX e o driver Realtek → limpo
2. Instalar somente Synapse + THX → **limpo**
3. Instalar o driver Realtek, com o serviço rodando → **ainda limpo**
4. **Reiniciar** → **contaminado**

O passo 3 mostra que não é a instalação em si que escreve. O passo 4 mostra o que escreve: o
serviço executando uma passagem completa de enumeração. (O serviço inicia a cada boot, mas
também roda em outros momentos durante o uso normal — então "no boot" descreve quando é mais
fácil observar, não uma condição necessária.)

---

## 4. O que a captura mostra de fato

Sequência executada pelo `RtkAudUService64.exe` no endpoint de renderização do headset:

```
lê      hardware IDs                 -> USB\VID_1532&PID_0555, driver usbaudio
lê      estado / propriedades        -> endpoint ativo
abre    FxProperties                 -> Read, Set Value
lê      ,13                          -> {C792E395-...}
grava   ,13                          -> {C792E395-...} , {905399BE-...}
lê      ,14                          -> {68650828-...}
grava   ,14                          -> {68650828-...} , {9063CBD4-...}
grava   ,19                          -> {90B31DF6-...}
grava   ,20                          -> {90C35236-...}
```

Ler, modificar e gravar, em cerca de 0,7 ms do início ao fim, **sem nenhuma consulta a preset,
política ou hardware entre a leitura e a escrita**. O serviço preserva o que já estava na cadeia
e anexa o dele — é por isso que o THX sobrevive e por isso que os dois acabam empilhados sobre o
mesmo fluxo.

Cerca de 8 ms antes, a mesma passagem reescreve a propriedade CompositeFX Mode do endpoint:

```
{d04e05a6-...},0 :  {DFF21CE1-F70F-11D0-B917-00A0C9223196}  ->  {00000000-0000-0000-0000-000000000000}
```

o que tira do endpoint a titularidade dos efeitos que haviam sido configurados para ele.

A mesma passagem percorre os endpoints HDMI da NVIDIA sem aplicar esse tratamento, então a
rotina não é literalmente "todo endpoint" — mas nada na captura mostra o teste sendo feito
contra algum valor que o usuário ou outro fabricante controle, que é o que uma correção
cirúrgica exigiria.

### Uma observação sobre outra leitura equivocada

Uma análise anterior registrou o endpoint da NVIDIA com `DeviceState = 9`, o que explicaria a
diferença. Esse valor é o `FormFactor = 9`; o `DeviceState` real do endpoint é `1`, o mesmo do
afetado. Vale mencionar porque as duas propriedades ficam próximas em uma exportação e a
confusão é fácil de herdar.

---

## 5. Por que a correção mira as permissões

Sem nenhuma entrada observável que decida o comportamento, não há o que configurar. O que resta
é negar a escrita em si.

O Windows permite dar ao serviço uma identidade própria:

```
sc.exe sidtype RtkAudioUniversalService unrestricted
```

O serviço passa a rodar como `NT SERVICE\RtkAudioUniversalService`, e uma ACE de Deny nomeando
essa identidade pode ser colocada na chave `FxProperties` do endpoint, para `SetValue`,
`CreateSubKey` e `Delete`, com `ContainerInherit, ObjectInherit`.

As chaves pertencem ao `TrustedInstaller`. Ser administrador dá o direito de *assumir* a
propriedade, mas não o de alterar permissões antes disso — e assumir exige o privilégio
`SeTakeOwnershipPrivilege` habilitado no token do processo, coisa que o PowerShell não faz
sozinho. É por isso que um `Set-Acl` simples falha com *"Acesso ao Registro solicitado não é
permitido"* mesmo em um prompt elevado, e por isso que a ferramenta habilita o privilégio via
`AdjustTokenPrivileges` antes de tocar na ACL.

---

## 6. Resultado

Verificado em várias reinicializações na máquina afetada:

- A cadeia de efeitos permanece como o THX configurou
- O serviço da Realtek continua em **Automático** e inicia normalmente
- O áudio Realtek onboard mantém todos os efeitos
- Synapse e THX configuram o headset sem nenhum erro

Depois de reiniciar, o serviço ainda cria o contexto CAPX no endpoint e grava metadados nele —
`{c4f6b0fa-...},0/,2/,2000/,3` e `{88d5b221-...},83` no store `User`, com o `Default` vazio —
mas não consegue mais tocar em `,13`, `,14`, `,19` ou `,20`. A negação está limitada exatamente
às propriedades que importam.

---

## 7. Perguntas em aberto

- **Qual é a condição interna.** O Process Monitor registra operações, não desvios de código. A
  captura não mostra consulta alguma entre a leitura e a escrita, o que elimina os candidatos
  alcançáveis mas não revela o que o binário avalia em memória.
- **Por que o gatilho é a reinstalação.** O GUID do endpoint muda quando o Synapse recria o
  dispositivo, então o endpoint afetado é um novo a cada vez. Se o GUID anterior tinha algo que
  o isentava, ou se o comportamento já existia antes da reinstalação e passava despercebido,
  não ficou estabelecido.
- **Qual é o alcance.** Relatos do mesmo padrão remontam a 2022 no fórum da comunidade da Razer,
  em hardware com codec Realtek. O mecanismo não é específico de marca.
