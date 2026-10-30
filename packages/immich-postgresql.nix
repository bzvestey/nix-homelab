{ pkgs }:
pkgs.postgresql_18.withPackages (extensions: [
  extensions.pgvector
  extensions.vectorchord
])
