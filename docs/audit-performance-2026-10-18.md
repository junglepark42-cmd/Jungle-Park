# Audit de performance — 18 octobre 2026

**Périmètre :** `junglepark42-cmd/Jungle-Park`, branche `perf/startup-lazy-anniversaires-20261018`. Aucun déploiement ni SQL d'écriture exécuté.

## Constats confirmés sur `main`
- `index.html` : 9 350 lignes, ~580 Ko avant compression.
- `doLogin()` attend `loadAllData()` avant `initApp()`, exposant une attente longue sur le tableau de bord.
- `loadAllData()` appelle séquentiellement plus de vingt lectures REST, notamment 10 000 températures, 10 000 contrôles de structures, 50 000 limites pour incidents/livraisons/checklists, et aussi courses, fournisseurs, locations.
- La même table `controles_periodiques` est lue deux fois.
- `checklist_config` contient une initialisation **avec écriture implicite** lorsqu'une lecture échoue ou renvoie vide : ce chemin devra être verrouillé, sans écrire à partir d'une absence de réponse.
- `loadAndRenderAnniv()` remplace les réservations par `[]` lorsque la requête échoue : une déconnexion est visuellement prise pour « aucun anniversaire ».
- Plusieurs modifications des anniversaires touchent des objets mémoire avant confirmation Supabase; la totalité des `options` est parfois envoyée en PATCH, exposant des mises à jour perdues en modification simultanée.
- `loadCourses()` existe déjà à l'ouverture de sa fenêtre : supprimer l'appel de démarrage est possible, mais il faudra corriger le cas « zéro article » et les échecs réseau.
- Les créneaux planning sont associés au **nom de l'employé** dans plusieurs chemins, ce qui demande une migration dédiée avant de corriger les renommages, hors de ce chantier de performance.

## Blocage de sécurité à traiter avant Realtime
- Le projet Supabase connecté est le bon (`hvimszqcomvvbogyztlb`).
- Les **24 tables du schéma public listées par Supabase ont RLS désactivée**, notamment `employes`, `planning` et `anniversaires`. Cela expose les données aux rôles disposant de la clé publique; l'application a en plus un login PIN purement client et une clé publique intégrée. Une simple activation RLS sans modèle Auth et politiques testées **couperait l'accès** : surtout ne pas lancer les instructions SQL d'activation en bloc.
- La publication `supabase_realtime` ne contient **aucune table** à ce stade.
- Ne publier que `public.anniversaires` après validation du modèle d'autorisation. Realtime ne résout pas les conflits de PATCH concurrents : il faut une logique d'écriture atomique/versionnée.

## Mesures
- Le délai de 10–20 s est **déclaré par l'utilisateur**. Aucun profil Chrome/mobile ni chrono réseau avant/après n'a encore été exécuté; ne pas annoncer 3 s comme acquis.
- Prévoir mesures `performance.now()` au login, à la première interface exploitable, et par module, p50/p95, réseau mobile normal et dégradé.

## Prochaines modifications conditionnées aux tests
1. Extraire des chargeurs avec états `idle/loading/loaded/error` et déduplication Promise.
2. Conserver employés + congés/indispos + planning courant + checklist du jour en chargement critique; charger les anniversaires du jour en parallèle.
3. Arrêter toute écriture de configuration automatique sur lecture nulle ou erreur.
4. Déclencher les historiques HACCP, structures, incidents, fournisseurs, locations et RH à la demande; préserver l'accès paginé aux périodes passées.
5. Ne jamais substituer `[]` à un échec réseau.
6. Implémenter Realtime **sur anniversaires seulement** après vérification des permissions et mécanisme de concurrence, puis tests croisés sur deux sessions.
7. Exécuter des validations mobiles/admin/employé et comparer l'initialisation avant/après.

## Statut
**Audit initial réalisé. Correctif applicatif non implémenté et tests fonctionnels non exécutés.** Aucun merge demandé ni autorisé.
