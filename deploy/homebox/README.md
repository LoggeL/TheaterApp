# Auto-Deploy auf HomeBox einrichten

Vorlagen für den Pull-Deployer `tool/autodeploy.py`. Ablauf und Betrieb stehen in [docs/operations.md](../../docs/operations.md#web-build-veröffentlichen). Hier steht nur die einmalige Einrichtung als Nutzer `logge`. Es gibt keinen eingehenden Port und keinen Runner am öffentlichen Repository.

**Vertrauensmodell:** Alles, was auf `main` landet und `verify` besteht, läuft danach ohne weitere Prüfung auf HomeBox, als `logge` (Docker-Gruppe, also Root-äquivalent). `tool/deploy.py` und `tool/backup.py` kommen aus dem gepushten Commit. Sie könnten auch den installierten Deployer, die Units, das GitHub-Token, den Dokploy-Schlüssel, die Backups und den `gh`-Login in `~/.config/gh/hosts.yml` lesen oder ändern. Bisher brauchte ein Deploy eine Person, die `deploy.py` startet. Jetzt reicht ein Push. Jede Berechtigung zum Pushen auf `main` ist damit ein Zugang zur Produktion, auch Tokens von Agenten oder Codex-Sitzungen.

1. Verzeichnisse und Clone anlegen. Nicht `~/projects/theater-app` (Live-Daten) und nicht `~/.hermes/workspace/theater-app` verwenden.

   ```sh
   mkdir -m 700 -p ~/projects/theater-autodeploy/{bin,state,work,backups} ~/.config/theater-autodeploy
   (umask 022; git clone --no-checkout https://github.com/LoggeL/TheaterApp.git ~/projects/theater-autodeploy/src)
   ln -sfn ~/.nvm/versions/node/v24.18.0 ~/projects/theater-autodeploy/node
   ```

   Nach einem nvm-Update nur den Symlink `node` neu setzen.

2. Zugangsdaten als reine Schlüsseldateien mit Modus 600 ablegen:
   - `~/.config/theater-autodeploy/github-token`: fine-grained PAT, nur `LoggeL/TheaterApp`, *Actions: Read-only*, mit Ablaufdatum. Nicht den breiten `gh`-Login von HomeBox wiederverwenden.
   - `~/.config/theater-autodeploy/dokploy-key`: Dokploy-API-Schlüssel.

   Auf GitHub vor dem Aktivieren des Timers (Schritt 6): ein Ruleset auf `main`, das Force-Push und Löschen verbietet und den Status-Check `verify` verlangt (Admin-Bypass nur, falls du direkt pushst). Fork-PR-Läufe nur nach Freigabe („all outside collaborators“). Push-Zugänge (Deploy-Keys, PATs, Agent-Tokens) so behandeln wie Zugänge zur Produktion.

3. `~/.config/theater-autodeploy/env` (Modus 600). systemd erweitert dort weder `~` noch `%h`, deshalb absolute Pfade:

   ```sh
   GH_TOKEN_FILE=/home/logge/.config/theater-autodeploy/github-token
   DOKPLOY_API_KEY_FILE=/home/logge/.config/theater-autodeploy/dokploy-key
   THEATER_BACKUP_DIR=/home/logge/projects/theater-autodeploy/backups
   # Optional: erhält einen kurzen deutschen Statustext als letztes Argument.
   # NOTIFY_CMD=/home/logge/.config/theater-autodeploy/notify
   # Optional: nur die neuesten N Backups behalten (mindestens 3). Ohne Angabe wird nichts gelöscht.
   # THEATER_BACKUP_KEEP=30
   ```

4. Den Deployer als Kopie installieren. Er läuft nicht direkt aus dem Clone, damit ein kaputter Commit nicht den Poller selbst lahmlegt. Eine Sicherheitsgrenze ist das nicht (siehe Vertrauensmodell oben): Code aus einem gepushten Commit kann diese Kopie überschreiben. Nach Änderungen an `tool/autodeploy.py` oder den Units diesen Schritt wiederholen.

   ```sh
   cd ~/projects/theater-autodeploy/src
   git fetch origin main
   git show origin/main:tool/autodeploy.py > ../bin/autodeploy.py && chmod 700 ../bin/autodeploy.py
   for unit in service timer; do
     git show origin/main:deploy/homebox/theater-autodeploy.$unit > ~/.config/systemd/user/theater-autodeploy.$unit
   done
   systemctl --user daemon-reload
   ```

5. Probelauf unter Aufsicht. Er lädt und prüft das Artefakt, checkt den Commit aus und testet, ob `version-web.mjs` den CI-Build unverändert lässt. Außerdem liest er über `compose.one` den Rückfallpunkt für den Rollback (aktuelle Compose-Datei und Release). Es gibt kein Backup und keinen Rollout, und er schreibt keinen Status.

   ```sh
   set -a; . ~/.config/theater-autodeploy/env; set +a
   PATH=~/projects/theater-autodeploy/node/bin:$PATH THEATER_AUTODEPLOY_HOME=~/projects/theater-autodeploy \
     python3 ~/projects/theater-autodeploy/bin/autodeploy.py --dry-run
   ```

6. Einen echten Durchgang starten und beobachten. Erst danach, und erst wenn das Ruleset aus Schritt 2 aktiv ist, den Timer aktivieren.

   ```sh
   systemctl --user start theater-autodeploy.service
   journalctl --user -u theater-autodeploy.service -n 100
   cat ~/projects/theater-autodeploy/state/deployed.json
   systemctl --user enable --now theater-autodeploy.timer
   ```
