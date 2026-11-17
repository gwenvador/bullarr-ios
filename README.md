# Bullarr iOS

Application iPhone et iPad (Swift, SwiftUI) qui pilote [Bullarr](https://github.com/gwenvador/bullarr),
le gestionnaire de bibliothèque BD, à travers son API. C'est le pendant iOS de
[Bullarr Android](https://github.com/gwenvador/bullarr-android). L'interface est en français.

- **Bibliothèque** : séries, tomes possédés et manquants, filtres, tags, univers, « Continuer la lecture ».
- **Recherche** : ajout de séries depuis Bedetheque, recherche des tomes manquants.
- **Suivi** : activité et téléchargements, nouveautés, validation des demandes, historique.
- **Actions** : enrichissement des métadonnées, surveillance, vérification.
- **Demandes** (comptes lecteurs) : demander des BD aux administrateurs.
- **Lecteur** : pages ou webtoon, sens manga, double page en paysage, zoom, miniatures, reprise
  synchronisée avec Komga, albums téléchargés pour une lecture hors ligne.
- **Réglages** : profil et configuration du serveur Bullarr (indexeurs, clients, notifications,
  utilisateurs…).

Il faut un serveur Bullarr déjà installé : voir [gwenvador/bullarr](https://github.com/gwenvador/bullarr).

## Installation

L'application n'est pas sur l'App Store. Apple n'autorise l'installation hors App Store qu'avec
une signature liée à **votre** compte Apple : il faut donc compiler l'app soi-même avec Xcode.
C'est gratuit avec un simple identifiant Apple.

### Ce qu'il faut

- Un Mac avec **Xcode 16** ou plus récent (gratuit sur le Mac App Store).
- Un iPhone ou un iPad sous **iOS 17** ou plus récent, et un câble (ou le même réseau Wi-Fi que le Mac).
- Un identifiant Apple. Un compte développeur payant n'est pas nécessaire (voir la limite plus bas).

### Étapes

1. **Récupérer le code**

   ```bash
   git clone https://github.com/gwenvador/bullarr-ios.git
   ```

   puis ouvrez `bullarr-ios/Bullarr.xcodeproj` dans Xcode.

2. **Ajouter votre compte Apple** : Xcode → Réglages → Comptes → « + » → Apple ID.

3. **Signer avec votre équipe** : sélectionnez le projet **Bullarr**, puis la cible **Bullarr** →
   onglet **Signing & Capabilities** :
   - **Team** : choisissez votre compte (« Votre Nom (Personal Team) ») ;
   - **Bundle Identifier** : remplacez `io.github.gwenvador.bullarr` par un identifiant à vous,
     par exemple `com.votrenom.bullarr` (un identifiant ne peut appartenir qu'à un seul compte).

4. **Préparer le téléphone** : branchez-le au Mac et acceptez « Faire confiance à cet ordinateur ».
   Activez ensuite le **mode développeur** : Réglages → Confidentialité et sécurité → Mode
   développeur, puis redémarrez le téléphone comme demandé.

5. **Installer** : en haut de la fenêtre Xcode, choisissez votre iPhone comme destination, puis
   **Product → Run** (⌘R). Xcode compile et installe l'application.

6. **Autoriser l'app** (compte gratuit seulement, au premier lancement) : Réglages → Général →
   **VPN et gestion de l'appareil** → votre identifiant Apple → **Faire confiance**.

> **Compte gratuit : l'app expire au bout de 7 jours.** Elle refuse alors de s'ouvrir ; il suffit
> de refaire **Product → Run** depuis Xcode pour la réinstaller (les réglages et les albums hors
> ligne sont conservés). Avec un compte Apple Developer payant, la signature dure un an.

### Mettre à jour

```bash
cd bullarr-ios
git pull
```

puis **Product → Run** à nouveau dans Xcode.

### Avec un fichier .ipa (AltStore, SideStore, Sideloadly)

Sans Mac ni Xcode : téléchargez `bullarr-ios-<version>.ipa` (non signée) depuis les
[releases](https://github.com/gwenvador/bullarr-ios/releases/latest), puis installez-la avec
[AltStore](https://altstore.io), [SideStore](https://sidestore.io) ou
[Sideloadly](https://sideloadly.io), qui la signent avec votre identifiant Apple. La limite des
7 jours du compte gratuit s'applique aussi ; AltStore et SideStore renouvellent l'app automatiquement.

## Premier lancement

Au premier lancement, renseignez l'**URL du serveur** (par exemple `http://192.168.1.10:4000`, ou
l'adresse publique de votre Bullarr ; le HTTP en clair est autorisé pour les serveurs du réseau
local), puis choisissez le mode d'accès :

- **Clé API** : dans Bullarr, **Paramètres → Login → carte « Accès API »**, générez la clé puis
  copiez-la. Si l'authentification de Bullarr est désactivée, laissez la clé vide.
- **Compte** : identifiant et mot de passe de Bullarr.
- **SSO** : l'identification OIDC se fait dans une fenêtre intégrée, puis l'app revient seule.

Touchez **Se connecter**. L'URL, la clé, les identifiants et la session sont chiffrés sur
l'appareil (trousseau iOS). Sans réseau, la rubrique **Hors ligne** donne accès aux albums téléchargés.

## Développement

Le projet Xcode est généré à partir de `project.yml` avec [XcodeGen](https://github.com/yonaskolb/XcodeGen).
Après une modification de `project.yml` (réglages, version, nouveau dossier de sources) :

```bash
brew install xcodegen
xcodegen generate
```

Les fichiers Swift sont dans `Bullarr/Sources` (`App`, `Data`, `Screens`). Il n'y a pas de
dépendance externe.

## Liens

- Serveur : [gwenvador/bullarr](https://github.com/gwenvador/bullarr)
- Application Android : [gwenvador/bullarr-android](https://github.com/gwenvador/bullarr-android)
- Signaler un problème : [issues](https://github.com/gwenvador/bullarr-ios/issues)
