# Runbook — voice-factory / Qwen3-TTS sur `gpu-ubuntu`

Guide court pour arrêter, relancer, et basculer entre voice-factory (Qwen3-TTS
via vLLM) et `apps/tts-server` (MOSS-TTS) sur la machine GPU dédiée.

## État par défaut

`gpu-ubuntu` héberge en permanence trois services systemd sous `ubuntu` :

| Service | Rôle | Port |
| --- | --- | --- |
| `voice-factory-vllm.service` | vLLM sert `Qwen3-TTS-12Hz-1.7B-Base` en mode `--omni` | `127.0.0.1:8004` |
| `voice-factory-proxy.service` | `qwen_clone_proxy.py` (adaptateur OpenAI `/v1/audio/speech` + auth Bearer, bind `0.0.0.0:8055`) | `:8055` |
| `voice-stt.service` | faster-whisper STT + alignement forcé | (local) |

Occupation VRAM : ~14.8 GiB sur la L4 (23 GiB), configurée via `--gpu-memory-utilization 0.6`.
Auth du proxy : `QWEN_CLONE_API_KEYS` dans `/home/ubuntu/voice-factory/proxy.env` (CSV, vide = pas d'auth).

## Arrêter voice-factory (préserver la config)

```bash
sudo systemctl stop voice-factory-proxy.service voice-factory-vllm.service voice-stt.service
sudo systemctl disable voice-factory-proxy.service voice-factory-vllm.service voice-stt.service
nvidia-smi   # VRAM utilisée doit tomber à ~0 MiB
```

Rien n'est supprimé : `/home/ubuntu/voice-factory/` (modèle, manifest, .env, proxy.py)
et les fichiers `.service` dans `/etc/systemd/system/` restent en place.

## Relancer voice-factory

```bash
sudo systemctl enable --now voice-factory-vllm.service voice-factory-proxy.service voice-stt.service
# ~50-60s pour que vLLM charge le checkpoint
for i in $(seq 1 30); do curl -sf http://127.0.0.1:8004/health >/dev/null && break; sleep 3; done
systemctl is-active voice-factory-vllm.service voice-factory-proxy.service voice-stt.service
curl -H "Authorization: Bearer <QWEN_CLONE_API_KEYS>" http://127.0.0.1:8055/v1/voices
```

Overrides systemd persistants (bind du proxy) : `/etc/systemd/system/voice-factory-proxy.service.d/override.conf`.

## Basculer sur `apps/tts-server` (MOSS)

**Prérequis :** GPU >= 24 GiB VRAM. La L4 (23 GiB) est sous-spécifiée — MOSS
OOM au chargement. Ne fonctionne qu'avec une L40 / A6000 / A100 40 GB+.

```bash
# 1. Libérer la VRAM
sudo systemctl stop voice-factory-proxy voice-factory-vllm voice-stt

# 2. Démarrer tts-server
cd /home/ubuntu/promptloom/apps/tts-server
docker compose up --build -d
docker compose logs -f tts   # ~30 min au 1er boot (téléchargement HF ~17 Go)
```

Côté worker video-api : basculer `.env` de `VIDEO_API_VOICE_ENGINE=openai`
vers `moss-remote`, mettre à jour `VIDEO_API_TTS_SERVER_URL`.

## Réseau

- **Tailscale** installé, hostname tailnet `l4-90-gra11-1`, IP `100.90.203.88`.
- **ufw** actif : SSH (22) + HTTP (80) + HTTPS (443) exposés publiquement,
  tout le reste (dont 8055) uniquement joignable depuis `100.64.0.0/10`.
- Vérif : `sudo ufw status verbose`.

## Diagnostic rapide

```bash
# VRAM + processes GPU
nvidia-smi

# Ports écoutés
ss -tlnp | grep -E ':(80|8004|8055|443|22)\b'

# Logs récents
sudo journalctl -u voice-factory-vllm -u voice-factory-proxy -u voice-stt --since "10 minutes ago"
```

## Fichiers clés

- `/etc/systemd/system/voice-factory-{vllm,proxy}.service` — définitions systemd
- `/etc/systemd/system/voice-factory-proxy.service.d/override.conf` — bind `0.0.0.0`
- `/home/ubuntu/voice-factory/proxy.env` — env vars du proxy (dont `QWEN_CLONE_API_KEYS`)
- `/home/ubuntu/voice-factory/qwen_clone_proxy.py` — code du proxy (auth Bearer patché)
- `/home/ubuntu/voice-factory/qwen_voices/manifest.json` — 48 voix disponibles
- `/home/ubuntu/promptloom/apps/tts-server/.env` — config MOSS (si activé)
