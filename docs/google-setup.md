# Connecter Capri à Google (Carnet + Tasks)

Capri parle à Google Docs (son « Carnet de Capri ») et à Google Tasks avec ton accord, sans jamais
connaître ton mot de passe. Pour ça, Google demande que l'app ait son propre « client OAuth », créé
une seule fois dans la console Google. Compte 10 minutes. C'est gratuit.

## 1. Créer un projet « Capri »

1. Va sur <https://console.cloud.google.com> avec ton compte Gmail.
2. En haut, clique sur le sélecteur de projet → **Nouveau projet**.
3. Nom : **Capri** → **Créer**, puis sélectionne ce projet.

## 2. Activer les trois API

Menu ☰ → **API et services** → **Bibliothèque**. Cherche et active (bouton **Activer**), une par une :

- **Google Tasks API**
- **Google Docs API**
- **Google Drive API**

## 3. L'écran de consentement

Menu ☰ → **Google Auth Platform** (selon la version, il s'appelle aussi « Écran de consentement OAuth »)
→ **Commencer** :

- Nom de l'application : **Capri**
- Adresse e-mail d'assistance : **ton Gmail**
- Audience : **Externe**
- Coordonnées : ton Gmail → accepte les conditions → **Créer**.

## 4. Accès aux données : les deux autorisations

**Accès aux données** → **Ajouter ou supprimer des niveaux d'accès**, puis colle dans « Ajouter
manuellement » :

```
https://www.googleapis.com/auth/tasks
https://www.googleapis.com/auth/drive.file
```

→ **Ajouter au tableau** → **Mettre à jour** → **Enregistrer**.

(`drive.file` ne donne accès qu'aux fichiers créés par Capri, comme son Carnet : pas au reste de ton Drive.)

## 5. Audience : publier l'application

**Audience** → **Publier l'application** → confirme.

Pourquoi ? En mode « Test », Google fait expirer la connexion au bout de 7 jours. Publiée, elle dure.
Tu n'as pas besoin de faire valider l'app par Google : elle n'est utilisée que par toi.

## 6. Créer le client « Application de bureau »

**Clients** → **Créer un client** :

- Type d'application : **Application de bureau**
- Nom : **Capri Mac**
- **Créer**, puis **Télécharger le fichier JSON**.

## 7. Donner le fichier à Capri

Renomme le fichier téléchargé (`client_secret_….json`) en **`google-oauth-client.json`** et
place-le dans :

```
~/Library/Application Support/Capri/google-oauth-client.json
```

Raccourci : dans le Finder, **Aller → Aller au dossier…** (⇧⌘G), colle
`~/Library/Application Support/Capri`, puis glisse le fichier dedans.

## 8. Se connecter

Menu de Capri (clic droit sur elle, ou l'icône dans la barre des menus) → **Connecter Google…**

1. Ton navigateur s'ouvre sur la page de Google : choisis ton compte.
2. Google affiche **« Google n'a pas validé cette application »** (normal : c'est ta propre app) →
   **Paramètres avancés** → **Accéder à Capri (non sécurisé)**.
3. Coche les deux autorisations → **Continuer**.
4. La page affiche « Connexion reçue » : tu peux fermer l'onglet. Le menu de Capri indique
   **Google : connecté ✓**.

## En cas de souci

- **Le menu dit « fichier google-oauth-client.json manquant »** : vérifie le nom exact et le dossier (étape 7).
- **« … illisible »** : le fichier n'est pas un client de type « Application de bureau » ; recrée-le (étape 6).
- **Erreur « access_denied » ou « non autorisé »** : vérifie l'étape 5 (app publiée) et les deux autorisations (étape 4).
- **Déconnecter** : menu de Capri → Google : connecté ✓ → **Déconnecter Google**. Tu peux aussi retirer
  l'accès sur <https://myaccount.google.com/permissions>.
