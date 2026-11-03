# Notifications internes

Le bouton flottant Urgence devient une cloche. Urgence reste accessible dans les actions de l’accueil. Les notifications sont enregistrées par destinataire dans rh_private.notifications, via une RPC utilisant les sessions RH existantes. Les demandes et les plannings ne sont ni supprimés ni dupliqués.

- Demande nouvelle ou remise en attente : notification aux gérants, accusé d’attente au salarié.
- Réponse : les alertes à traiter deviennent obsolètes pour les deux gérants ; le salarié reçoit la réponse.
- Lecture : persistante par personne, synchronisée entre appareils, jamais recréée par un rechargement.
- Rafraîchissement : connexion, retour/focus (temporisation 15 s), une fois/minute si l’application est visible. Aucun rechargement global. Une requête simultanée maximum ; liste limitée aux 50 derniers non-lus et compteur total. Les réponses après déconnexion sont ignorées.
- Lu : clic sur une notification ou bouton Lu. Tout marquer lit uniquement jusqu’au dernier identifiant connu, sans avaler les nouvelles arrivées.

Déploiement : appliquer sql/internal_notifications.sql, vérifier la conservation des 101 indisponibilités et le hash avant/après, puis fusionner cette branche. La migration est additive et initialise seulement les demandes encore en attente dont la date n’est pas passée. Réexécution sans résurrection des lectures. Ne pas publier le frontend avant la migration.

Validation : npm run test:notifications (tests client et PostgreSQL embarqué). Les droits anonymes hérités des anciennes tables de l’application restent une limite préexistante ; cette migration n’élargit pas leurs permissions et garde la nouvelle table privée.
