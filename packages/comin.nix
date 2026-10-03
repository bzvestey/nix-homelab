{ comin }:
comin.overrideAttrs (old: {
  # go-git before 5.16.3 drops Jujutsu's change-id header while reconstructing
  # the signed payload. Keep Comin itself pinned and update only this module.
  patches = (old.patches or [ ]) ++ [ ../checks/comin-go-git-5.16.3.patch ];
  vendorHash = "sha256-TMGkO9wcG+e1MfFo23QeX6T9K902BlTQs1e0ym/s3vY=";
})
