# Capri — compagnon de bureau macOS

Capri (Cyberpunk: Edgerunners 2) se balade en bas de ton écran, s'assoit, jongle, pirate
sur son ordi, sort la tête du bas de l'écran, se téléporte en glitch… et réagit quand tu
la cliques, la caresses ou la déplaces. Projet perso, pour apprendre AppKit et SpriteKit.

> Étapes faites : 1. Capri sur le bureau, 2. la discussion avec sa personnalité.
> À venir : 3. les outils d'assistante (rappels, apps, Raccourcis), 4. de vraies animations image par image.

## Lancer Capri

### Depuis le Terminal

```bash
cd ~/Project/Capri
./Scripts/run.sh
```

Le script compile en mode release, fabrique `build/Capri.app`, le signe localement et le lance.
Pour la quitter : clic droit sur elle (ou l'icône dans la barre des menus) → « Quitter Capri ».

Pour tester rapidement pendant le développement (sans fabriquer l'app) :

```bash
swift run
```

### Depuis Xcode

Ouvre `Package.swift` avec Xcode (double-clic, ou `open Package.swift`), choisis le schéma
« Capri » et « My Mac », puis ▶︎. Xcode n'est pas obligatoire : les outils en ligne de
commande suffisent pour `swift build` et `Scripts/run.sh`.

## Ce qu'elle sait faire

| Action | Réaction |
|---|---|
| Clic (ou ⌃⌥C, n'importe où) | Ouvre ou ferme la bulle de discussion. 3 clics rapides : elle se débat. |
| Va-et-vient de la souris sur elle | Caresse : yeux en cœur, rebonds, petits cœurs, et une petite réplique. |
| Glisser | Tu l'attrapes (pose « pull »), elle se débat si tu secoues. Lâchée, elle tombe et s'écrase au sol. |
| Clic droit / icône de la barre des menus | Menu : Discuter, Nouvelle conversation, Cerveau, Modifier sa personnalité…, Rester tranquille / Reprendre, Dormir, Taille, Quitter. |
| 3 min sans toucher l'ordi | Elle s'endort. N'importe quelle action la réveille. |

Les clics sur les zones transparentes autour d'elle passent à travers, et cliquer sur elle ne
retire pas le focus à l'app que tu utilises. Aucune permission macOS n'est demandée.

## Discuter avec Capri

Clique sur elle (ou ⌃⌥C depuis n'importe quelle app) : une bulle façon terminal de netrunner
s'ouvre au-dessus d'elle. Tape ton message, Entrée pour envoyer, Échap pour fermer, ■ pour
l'interrompre. Pendant la discussion, elle reste à côté de la bulle :

- elle tape sur son ordi (pose `hacking`) le temps de réfléchir ;
- dès ses premiers mots, elle prend la pose de son humeur, et la garde 6 à 8 s après sa réponse ;
- « Nouvelle conversation » (menu) lui fait tout oublier.

La bulle reçoit le clavier sans « voler » le premier plan : l'app que tu utilisais reste active.

### Son cerveau

**Claude (par défaut)** : Capri lance le vrai programme `claude` (Claude Code), avec ton abonnement.
Pour chaque message, elle exécute en gros :

```bash
claude -p "ton message" --output-format stream-json --verbose --include-partial-messages \
  --system-prompt "<sa personnalité>" --system-prompt-snapshot off --tools "" \
  --strict-mcp-config --setting-sources "" --model sonnet --resume <conversation>
```

- sa personnalité remplace entièrement le prompt de Claude Code ;
- aucun outil, aucun serveur MCP, aucun de tes réglages : elle ne peut que parler ;
- elle tourne dans un dossier vide, `~/Library/Application Support/Capri/brain` ;
- la réponse arrive en direct (stream-json), et `--resume` garde le fil de la conversation.

Si `claude` n'est pas trouvé ou n'est pas connecté, elle le dit dans la bulle, avec la cause technique.

**Ollama (optionnel)** : un modèle qui tourne sur ton Mac, sans Internet. Si Ollama est installé
et lancé, choisis « Cerveau → Ollama » dans le menu. Sinon l'entrée affiche « (non installé) ».

### Réglages

Le fichier `~/Library/Application Support/Capri/settings.json` (créé au premier lancement) :

```json
{
  "brain" : "claude",          // ou "ollama"
  "claudeModel" : "sonnet",    // "sonnet" répond en ~2 s ; "haiku" ~3-4 s ; "opus" plus lent
  "ollamaModel" : "llama3.2",  // un modèle de `ollama list`
  "timeoutSeconds" : 60        // délai max sans réponse
}
```

(Le JSON n'accepte pas les commentaires : ils sont là juste pour l'explication.)
Tu peux aussi ajouter `"claudePath" : "/chemin/vers/claude"`. Relance Capri après une modification.

### Sa personnalité

Tout est dans `Persona/capri.md` : sa voix, ses tics, ce qu'elle peut faire ou pas, et les
humeurs. Menu → « Modifier sa personnalité… » l'ouvre dans TextEdit. Elle relit ce fichier à
chaque message : enregistre, et sa réponse suivante en tient compte, sans recompiler. Git garde
l'historique de tes modifications. À chaque message, l'app ajoute la date et l'heure du moment.

Chaque réponse commence par une balise d'humeur (cachée à l'écran) qui choisit sa pose :

| Humeur | Pose | Humeur | Pose |
|---|---|---|---|
| joyeuse | juggle | endormie | sleepy |
| curieuse | sit_curious | concentree | hacking |
| taquine | sit_swing | fiere | lounge |
| amoureuse | love | fete | handstand |
| confuse | confused | calme (ou inconnue) | float |
| agacee | struggle | | |

Les petites répliques sans IA (caresse, chute, secousse, réveil) sont dans
`Sources/Capri/Chat/LocalLines.swift` (il faut relancer `Scripts/run.sh` après modification).

### Modes de test (cachés)

```bash
build/Capri.app/Contents/MacOS/Capri --selftest "Salut Capri" "De quoi on parlait ?"
```

Envoie les messages au cerveau, dans une même conversation, et affiche l'humeur, la réponse et
les temps de réponse, sans interface. `--render-ui <dossier>` dessine les bulles en PNG, et
`--open-chat "message"` ouvre la bulle et envoie un message au lancement.

## Organisation des fichiers

```
Capri/
├── Package.swift                 # le projet SwiftPM (aucune dépendance externe)
├── Scripts/run.sh                # compile + fabrique Capri.app + lance
├── Tools/slice-sprites.swift     # découpe la planche en sprites transparents
├── Assets/
│   ├── source/capri-sheet.webp   # la planche d'origine
│   └── preview/                  # planches d'aperçu générées (fond clair / sombre)
└── Sources/Capri/
    ├── main.swift                # point d'entrée : crée l'app et le AppDelegate
    ├── Pose.swift                # les 13 poses et les 3 tailles
    ├── SpriteLibrary.swift       # charge les PNG (textures + masques de transparence)
    ├── BehaviorMachine.swift     # le « cerveau » : états et choix des activités
    ├── PetController.swift       # chef d'orchestre : déplacements, souris, écrans
    ├── PetScene.swift            # l'affichage SpriteKit et tous les effets
    ├── PetPanel.swift            # la fenêtre transparente + la vue qui reçoit la souris
    ├── Watchers.swift            # surveille la souris (clics à travers, caresses) et l'inactivité
    ├── CapriMenu.swift           # le menu (clic droit et barre des menus)
    ├── Chat/
    │   ├── ChatBrain.swift       # le protocole « cerveau » et les erreurs
    │   ├── ClaudeBrain.swift     # cerveau Claude : lance `claude` et lit son flux JSON
    │   ├── OllamaBrain.swift     # cerveau Ollama : HTTP sur localhost:11434
    │   ├── ChatModel.swift       # la conversation : messages, envoi, humeurs
    │   ├── ChatView.swift        # la bulle en SwiftUI (style netrunner)
    │   ├── ChatWindows.swift     # les fenêtres des bulles et leur placement
    │   ├── Mood.swift            # humeurs → poses, et lecture de la balise
    │   ├── Persona.swift         # lit Persona/capri.md + date et heure
    │   ├── LocalLines.swift      # petites répliques sans IA
    │   ├── Settings.swift        # settings.json
    │   ├── HotKey.swift          # le raccourci global ⌃⌥C
    │   └── SelfTest.swift        # modes de test cachés
    └── Resources/Sprites/*.png   # les sprites découpés
Persona/capri.md                  # SA PERSONNALITÉ (modifiable sans recompiler)
```

Pour régénérer les sprites (par exemple avec une nouvelle planche) :

```bash
swift Tools/slice-sprites.swift
```

## Comment ça marche

**Une fenêtre transparente.** Capri vit dans un petit `NSPanel` sans bord, au fond transparent,
un peu plus grand qu'elle. Il est « non-activating » (le cliquer ne vole pas le focus), flotte
au-dessus des fenêtres normales et existe sur tous les Spaces. Pour la déplacer, on déplace
simplement la fenêtre. Son bord bas est posé sur le « sol » : le bas de la zone utile de
l'écran, juste au-dessus du Dock.

**Les clics à travers le vide.** Environ 20 fois par seconde, on lit la position de la souris.
Si elle est sur un pixel visible de Capri, la fenêtre capte la souris, sinon elle la laisse
passer (`ignoresMouseEvents`). Les masques de transparence des sprites servent à ce test.

**La boucle de comportement.** `BehaviorMachine` est une machine à états : Capri est toujours dans
un seul état (`floating`, `sitting`, `sleeping`…). Toutes les 5 à 20 secondes, elle tire au sort
une nouvelle activité, avec des poids (la balade est fréquente, l'équilibre sur les mains rare).
Les clics, caresses et glisser provoquent des transitions. La machine ne dessine rien : elle
annonce le nouvel état, et `PetController` le met en scène.

**Les poses.** On n'a qu'une image par pose, alors on les anime « à la main » avec SpriteKit :
respiration (étirement vertical de 2 %), miroir selon la direction, lévitation sinusoïdale,
petits sauts, balancements. Chaque changement de pose est masqué par un scintillement glitch de
~120 ms. La téléportation combine tremblements, copies magenta et cyan décalées (« RGB split »)
et un écrasement en ligne, comme un vieil écran qui s'éteint. Toutes les poses partagent le même
canevas, ancré en bas au centre : changer de pose ne la fait pas sauter.

**La discussion.** Un clic passe par `PetController.handleClick()`, qui ouvre la bulle et
prévient la machine à états (état `chatting` : elle arrête de se balader). `ChatModel` envoie le
message au cerveau actif via le protocole `ChatBrain`, et reçoit la réponse morceau par morceau.
`MoodParser` repère la balise d'humeur au tout début du flux, la retire du texte, et la machine
passe en `emoting(pose)`. Changer de cerveau ne touche qu'à une ligne : celle qui choisit l'objet
`ChatBrain` à utiliser.

**Rester léger.** Le nombre d'images par seconde dépend de l'activité (12 quand elle est assise,
60 pendant un glisser), et l'affichage est mis en pause quand elle dort ou que l'écran est éteint.
