# Faxina

App nativo de Mac (SwiftUI) para liberar espaço e organizar arquivos. Nada é apagado direto: tudo vai para a Lixeira ou para o Google Drive, e pode ser desfeito.

## Abas

- **Arquivos pesados**: arquivos de 100 MB ou mais na pasta pessoal; mover para a Lixeira ou fazer upload no Google Drive.
- **Caches e sobras**: caches que se refazem sozinhos (com botão Limpar) e pastas grandes para revisar.
- **Aplicativos**: apps instalados por tamanho e último uso; a remoção de apps protegidos passa pelo Finder, que pede a senha.
- **Memória**: RAM, swap e os apps que mais consomem.
- **Organizador**: regras palavra no nome → pasta de destino para os arquivos soltos do Downloads, com prévia.
- **Uploads**: andamento de cada envio ao Google Drive.
- **Últimas ações**: histórico com desfazer arquivo por arquivo.

O upload usa o app Google Drive para Mac: o arquivo é movido para `Meu Drive/Arquivo do Mac` e a cópia local só é liberada depois que o envio termina.

## Compilar

Precisa de macOS 15+ e das Command Line Tools (não precisa do Xcode).

```
./build.sh             # gera dist/Faxina.app
./build.sh --instalar  # também copia para /Applications e abre
```

Por padrão o script assina ad-hoc, e o macOS pede as permissões de novo a cada compilação. Para manter as permissões, crie um certificado local de assinatura de código e aponte para ele no arquivo `.assinatura.local` (fora do repositório); as variáveis estão descritas no `build.sh`.

O ícone é gerado por `python3 icone/montar.py` a partir de `icone/arte.png` (precisa do Pillow).

## Instalar com o Claude

Abra esta pasta no Claude Code e peça para instalar o Faxina. O `CLAUDE.md` orienta o Claude a compilar, instalar e propor regras do Organizador de acordo com o seu perfil; o app vem sem regras prontas.

## Dados

Histórico e regras ficam em `~/Library/Application Support/Faxina/`.

## Licença

MIT. O app move arquivos, remove aplicativos e limpa caches: use por sua conta e confira a prévia antes de confirmar cada ação. Veja `LICENSE`.
