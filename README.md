# Capri — compagnon de bureau macOS

Capri (Cyberpunk: Edgerunners 2) se balade en bas de ton écran, s'assoit, jongle, pirate
sur son ordi, sort la tête du bas de l'écran, se téléporte en glitch… et réagit quand tu
la cliques, la caresses ou la déplaces. Projet perso, pour apprendre AppKit et SpriteKit.

> Étape 1 sur 4 : Capri sur le bureau. Viendront ensuite la discussion avec l'IA (étape 2),
> les outils d'assistante (étape 3) et de vraies animations image par image (étape 4).

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
| Clic | Surprise (« ? ») avec un petit saut. 3 clics en 2 s : elle se débat. |
| Va-et-vient de la souris sur elle | Caresse : yeux en cœur, rebonds, petits cœurs. |
| Glisser | Tu l'attrapes (pose « pull »), elle se débat si tu secoues. Lâchée, elle tombe et s'écrase au sol. |
| Clic droit / icône de la barre des menus | Menu : Discuter (bientôt), Rester tranquille / Reprendre, Dormir, Taille, Quitter. |
| 3 min sans toucher l'ordi | Elle s'endort. N'importe quelle action la réveille. |

Les clics sur les zones transparentes autour d'elle passent à travers, et cliquer sur elle ne
retire pas le focus à l'app que tu utilises. Aucune permission macOS n'est demandée.

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
    └── Resources/Sprites/*.png   # les sprites découpés
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

**Rester léger.** Le nombre d'images par seconde dépend de l'activité (12 quand elle est assise,
60 pendant un glisser), et l'affichage est mis en pause quand elle dort ou que l'écran est éteint.
