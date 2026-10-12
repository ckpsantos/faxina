# Faxina: instruções para o Claude

App nativo de Mac em SwiftUI, compilado só com as Command Line Tools (sem Xcode). O `README.md` descreve as abas e os comandos.

## Ao instalar para alguém

Quando a pessoa pedir para instalar ou configurar o Faxina, faça nesta ordem:

1. Confira os requisitos: macOS 15 ou mais novo e Command Line Tools (`xcode-select -p`). Se faltar, oriente `xcode-select --install`.
2. Rode `./build.sh --instalar`. Ele compila, copia para `/Applications/Faxina.app` e abre.
3. Avise que o macOS vai pedir permissão para Downloads, Documentos e Mesa na primeira varredura, e para controlar o Finder ao remover apps protegidos.
4. Proponha as regras do Organizador sob medida para a pessoa (seção abaixo). O app vem sem nenhuma regra de propósito.

## Regras do Organizador sob medida

O repositório não traz regras prontas porque elas dependem de como cada pessoa trabalha. Monte uma proposta a partir do perfil dela, não de um modelo genérico:

1. Peça licença para olhar, só em modo leitura, os nomes de arquivo do `~/Downloads` e a estrutura de pastas onde a pessoa guarda trabalho (Documentos, pastas de projetos, clientes, estudos).
2. Use também o que você já sabe dela: profissão, clientes, projetos, cursos, e o que estiver na memória ou nos arquivos de instrução dela.
3. Procure os termos que mais se repetem nos nomes de arquivo do Downloads (cliente, projeto, tipo de documento) e a pasta que já existe para cada um.
4. Mostre a proposta em tabela: palavras, pasta de destino e quantos arquivos do Downloads cada regra pegaria hoje. Diga o que foi dedução sua.
5. Só grave depois que a pessoa aprovar. Nunca mova arquivos por conta própria: quem move é ela, pelo botão do app, depois de ver a prévia.

Critérios para uma boa regra:

- A palavra precisa ter 3 letras ou mais e aparecer inteira no nome do arquivo. Maiúsculas, acentos, hífen e sublinhado não fazem diferença.
- Evite palavras comuns ("relatorio", "final", "novo"), que pegam arquivos de assuntos diferentes.
- Prefira destinos que já existem. Se a pessoa usa uma pasta de entrada por projeto, aponte para ela.
- Se duas regras casarem com o mesmo arquivo, ganha a palavra mais longa.

### Onde gravar

`~/Library/Application Support/Faxina/regras.json`, com o app fechado (ele lê o arquivo ao abrir). Se o arquivo já existir, leia antes e acrescente em vez de substituir.

```json
[
  {
    "id": "6F1C2B4E-8A3D-4E5F-9B7A-1C2D3E4F5A6B",
    "palavras": "contrato, aditivo",
    "destino": "/Users/nome/Documents/Contratos",
    "ativa": true
  }
]
```

- `id`: um UUID por regra (`uuidgen`).
- `palavras`: uma ou mais, separadas por vírgula.
- `destino`: caminho absoluto da pasta.

## Ao mexer no código

- Nada apaga direto. Toda remoção vai para a Lixeira e toda ação entra no histórico para poder ser desfeita.
- O texto da interface é em português do Brasil.
- Não coloque no código nomes de clientes, pastas pessoais ou regras de uma pessoa específica: o repositório é para qualquer um instalar.
- Depois de alterar, rode `./build.sh --instalar` e confira a tela afetada no app aberto.
