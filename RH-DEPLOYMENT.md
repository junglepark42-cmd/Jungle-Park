# Suivi des contrats — novembre 2026

Le calcul saisonnier est dans `rh-contracts.js`. Le moteur CDI historique reste distinct ; ses agrégats sont bornés à la période CDI lorsqu'un historique de contrats est confirmé.

## Ordre de déploiement

1. Vérifier la version GitHub et répéter `sql/rh_contracts.sql` sur une copie de travail.
2. Appliquer cette migration additive dans Supabase. Elle capture les six tables RH/planning concernées dans `rh_private.backup_20261102` avant toute modification. Cette sauvegarde contient des informations personnelles : ne jamais la publier dans GitHub.
3. Exécuter `sql/verify_rh_history.sql` : aucun ancien champ de planning ne doit différer.
4. Publier ensemble `index.html` et `rh-contracts.js`, puis vérifier le site.

## Première utilisation

Se reconnecter. Ouvrir RH → fiche personne → Contrats et historique.
Les données précédentes sont importées sans inventer une date de fin ou un volume saisonnier. Vérifier les dates réelles, choisir le compteur saisonnier, saisir le total contractuel et contrôler les objectifs de chaque mois. Confirmer seulement quand ces données sont exactes. Les objectifs mensuels doivent totaliser la référence. Le 1er novembre n'est pas une remise à zéro.

La confirmation rattache les créneaux existants qui correspondent de façon certaine. Les créneaux plus anciens ou non rattachés restent consultables via « Tout l'historique des plannings ». Le nouveau contrat d'une saison suivante doit être créé sans écraser le précédent. Terminer d'abord la période précédente pour éviter un chevauchement.

Les compteurs affichent le réalisé validé, le passé encore provisoire et les prévisions futures. Les semaines vides doivent être explicitement marquées préparées pour représenter un repos volontaire. Les paiements ne diminuent jamais le volume consommé au titre des 25 %.

La validation des heures se fait depuis le détail du contrat, en heures décimales, pauses déduites, avec motif. Les absences ne sont pas assimilées automatiquement à du travail effectif : leurs éventuelles règles de neutralisation doivent être définies avant de les automatiser. Le planning historique seul n'est pas une preuve d'heures effectuées.

## Accès

Les nouvelles données et sauvegardes sont dans un schéma privé, RLS activée, sans accès direct anon/authenticated. La RPC vérifie une session serveur de huit heures obtenue par le PIN existant, le statut gérant et l'archivage à chaque appel. Une personne archivée ne peut plus obtenir de session. La connexion et les sessions des anciens salariés avec date de fin passée sont refusées.

Limite héritée : les anciennes tables publiques de l'application n'ont pas de RLS et les PIN y sont accessibles selon leurs droits actuels. Le nouveau module ne résout pas cette faille globale. Une migration complète de l'authentification et des accès de tous les modules reste nécessaire. Ne pas activer brutalement RLS sur ces tables sans adapter leurs accès.

## Retour arrière

Revenir au commit applicatif précédent via GitHub. Conserver les nouvelles tables, leurs sauvegardes et leurs données privées ; les colonnes ajoutées sont compatibles avec l'ancien code. Ne pas restaurer aveuglément une sauvegarde sur des données qui auraient changé depuis. Faire une restauration ciblée uniquement si une différence historique a été identifiée. Les clés étrangères empêchent la suppression physique des personnes importées et des créneaux validés.

## Tests

`npm ci && npm test` : calculs de plafond, franchissement d'année, heures réelles remplaçant les prévisions, planning incomplet, puis migration sur PostgreSQL embarqué et nouvelle exécution sans doublons, conservation des données, chevauchements, validations et archivage.
