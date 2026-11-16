# HbSync — liaison entre iPads (Taguage live ↔ Temps de jeu)

Module Capacitor (iOS, Swift, Network.framework, aucune librairie tierce) qui relie deux applis iPad pendant un match, **sans internet** :

- découverte automatique en Bonjour (`_hbsync._tcp`), sans adresse IP à saisir ;
- fonctionne sur le Wi-Fi du routeur (GL.iNet Beryl AX, réseau HB-SYNC) **ou en direct entre iPads** quand ils sont proches (Wi-Fi et Bluetooth activés) ;
- échange de messages JSON (une ligne JSON par message).

Le module ne connaît rien du handball et ne se reconnecte jamais tout seul : il signale les changements d'état, et c'est l'appli qui décide (voir la spécification, sections 5 et 6).

Spécification de référence : https://claude.ai/artifact/C5qoeQXJ76zdzytQnmENJd

## Installation dans une appli (même modèle que tdj-speech)

1. Dans `package.json` de l'appli, ajouter dans `dependencies` :

   ```json
   "hbsync": "github:handvince/hbsync-capacitor"
   ```

2. `npm install`, puis `npx cap sync ios` (fait aussi par le workflow GitHub Actions).

3. Dans `ios/App/App/Info.plist`, ajouter avant le dernier `</dict>` :

   ```xml
   <key>NSLocalNetworkUsageDescription</key>
   <string>Permet de relier Taguage live et Temps de jeu pendant le match.</string>
   <key>NSBonjourServices</key>
   <array>
       <string>_hbsync._tcp</string>
   </array>
   ```

   Sans ces deux entrées, iOS bloque la liaison sans message d'erreur clair.

## Utilisation depuis la page web

```js
const CAP = window.Capacitor;
const HbSync = CAP.Plugins.HbSync || CAP.registerPlugin('HbSync');

// Événements
HbSync.addListener('state',     e => console.log(e.state, e.role, e.detail));
HbSync.addListener('message',   e => traiterMessage(e.message));
HbSync.addListener('peerFound', e => afficherIpad(e.peerId));   // côté client
HbSync.addListener('peerLost',  e => masquerIpad(e.peerId));    // côté client

// Taguage live (hôte)
await HbSync.startHost({ name: 'Taguage live – iPad banc' });

// Temps de jeu (client)
await HbSync.startBrowse();
await HbSync.connect({ peerId: 'Taguage live – iPad banc' });

// Envoi (les deux)
await HbSync.send({ message: { v: 1, type: 'ping', body: { t1: performance.now() / 1000 } } });
```

### Méthodes

| Méthode | Rôle | Effet |
| --- | --- | --- |
| `startHost({ name })` / `stopHost()` | Hôte | Ouvre / ferme l'écoute et l'annonce Bonjour |
| `startBrowse()` / `stopBrowse()` | Client | Cherche les iPads hôtes |
| `connect({ peerId })` / `disconnect()` | Client | Ouvre / ferme la liaison avec l'hôte choisi |
| `send({ message })` | Les deux | Envoie un objet JSON. Erreur `not_connected` si pas de liaison |
| `status()` | Les deux | `{ role, state, peers, peer }` |

### États (`state`)

| État | Signification |
| --- | --- |
| `idle` | Liaison inactive |
| `listening` | Hôte en attente d'un client |
| `searching` | Client en recherche d'hôte |
| `connecting` | Liaison en cours d'ouverture |
| `connected` | Reliés : les messages passent |
| `failed` | Liaison perdue ou impossible (`detail` donne la raison). Côté client, l'appli relance `connect` toutes les 2 s |

Côté hôte, la perte du client ramène à `listening`. Un nouveau client remplace l'ancien (une seule liaison à la fois en v1).

## Points d'attention en match

- Garder l'appli **au premier plan** et l'écran allumé : iOS coupe le réseau d'une appli en arrière-plan. Au retour au premier plan, le module relance seul l'écoute ou la recherche.
- La première fois, iOS demande « Autoriser l'accès au réseau local ? » : répondre **Autoriser** sur les deux iPads (sinon : Réglages › Confidentialité › Réseau local).
