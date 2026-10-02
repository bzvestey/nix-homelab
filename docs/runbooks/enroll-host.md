# Enroll a host for sops-nix

Host enrollment happens only after first boot creates the real Ed25519 SSH
host key. Do not fabricate production recipients or copy a private key.

1. Keep bootstrap SSH and comin available. On the host, run `fleet-enroll`.
   It reads only `/etc/ssh/ssh_host_ed25519_key.pub` and prints the SSH public
   key, derived age recipient, and exact `.sops.yaml` host anchor.
2. Add that public recipient to the documented host anchor insertion point.
   Add it only to its per-host rule and, when applicable, `pi-connectors` or
   `framework-runners`. There is intentionally no universal fleet group.
3. Rewrap affected encrypted files with `sops updatekeys <file>`. Inspect the
   diff to ensure it contains encrypted metadata only, then make a signed
   commit and let comin deploy it.
4. Confirm the new host decrypts its secrets and all secret-dependent units
   are healthy. Bootstrap SSH/comin must remain independent of application
   secret decryption.
5. Only after that confirmation, remove any old recipient, run
   `sops updatekeys` again, inspect the diff, and make another signed commit.

## Credential rotation

Rotate the credential inside `sops <file>`, deploy it, verify consumers, and
then revoke the old credential at its issuer. Recipient rotation is separate:
add and prove the new recipient before removing the old one. Never place
plaintext, source kubeconfigs or Talos configs/state, private keys, generated
credentials, or decrypted sops output in Git or the Nix store.
