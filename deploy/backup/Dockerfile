# Sauvegardes planifiées de la base MySQL et des fichiers uploadés (voir backup.sh).
# Base mysql:8.4 : fournit mysqldump/mysql de la même version que le serveur, plus
# bash, gzip, tar, openssl et curl. rclone (binaire statique) sert à la copie hors serveur.
FROM rclone/rclone:1.68 AS rclone

FROM mysql:8.4
COPY --from=rclone /usr/local/bin/rclone /usr/local/bin/rclone
COPY backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh
ENTRYPOINT ["/usr/local/bin/backup.sh"]
CMD ["daemon"]
