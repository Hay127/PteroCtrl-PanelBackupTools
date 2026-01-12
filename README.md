<!-- Improved compatibility of back to top link: See: https://github.com/othneildrew/Best-README-Template/pull/73 -->
<a id="readme-top"></a>

<!-- PROJECT SHIELDS -->
[![Contributors][contributors-shield]][contributors-url]
[![Forks][forks-shield]][forks-url]
[![Stargazers][stars-shield]][stars-url]
[![Issues][issues-shield]][issues-url]
[![MIT License][license-shield]][license-url]



<!-- PROJECT LOGO -->
<br />
<div align="center">
  <a href="https://github.com/YOUR_USERNAME/YOUR_REPO">
    <img src="images/logo.png" alt="Logo" width="90" height="90">
  </a>

  <h3 align="center">Segeng Full Backup</h3>

  <p align="center">
    Backup otomatis untuk <b>Pterodactyl Panel</b> + <b>CtrlPanel</b> dalam 1 VPS: DB dump, tar compress (zstd), upload rclone, retensi, webhook Discord, anti double-run.
    <br />
    <a href="#getting-started"><strong>Get Started »</strong></a>
    <br />
    <br />
    <a href="#usage">Usage</a>
    &middot;
    <a href="https://github.com/YOUR_USERNAME/YOUR_REPO/issues">Report Bug</a>
    &middot;
    <a href="https://github.com/YOUR_USERNAME/YOUR_REPO/issues">Request Feature</a>
  </p>
</div>



<!-- TABLE OF CONTENTS -->
<details>
  <summary>Table of Contents</summary>
  <ol>
    <li>
      <a href="#about-the-project">About The Project</a>
      <ul>
        <li><a href="#what-this-backs-up">What This Backs Up</a></li>
        <li><a href="#built-with">Built With</a></li>
      </ul>
    </li>
    <li>
      <a href="#getting-started">Getting Started</a>
      <ul>
        <li><a href="#prerequisites">Prerequisites</a></li>
        <li><a href="#installation">Installation</a></li>
        <li><a href="#configuration">Configuration</a></li>
      </ul>
    </li>
    <li><a href="#usage">Usage</a></li>
    <li><a href="#restore">Restore</a></li>
    <li><a href="#security-notes">Security Notes</a></li>
    <li><a href="#roadmap">Roadmap</a></li>
    <li><a href="#contributing">Contributing</a></li>
    <li><a href="#license">License</a></li>
    <li><a href="#contact">Contact</a></li>
    <li><a href="#acknowledgments">Acknowledgments</a></li>
  </ol>
</details>



<!-- ABOUT THE PROJECT -->
## About The Project

Segeng Full Backup adalah script Bash untuk melakukan backup otomatis **control-plane** pada VPS yang menjalankan:

- ✅ **Pterodactyl Panel** (file app + database)
- ✅ **CtrlPanel (Laravel)** (file app + database)
- ✅ **System configs**: Nginx, Let’s Encrypt, Pterodactyl config, systemd, cron

Fitur tambahan:
- ✅ kompresi **zstd / pigz / gzip**
- ✅ upload ke remote via **rclone** (Nextcloud/GDrive/S3/etc) atau **rsync over SSH**
- ✅ **Discord webhook notification** (dengan retry)
- ✅ **retention cleanup** (local & remote)
- ✅ **anti double-run** (lock) jadi aman dipakai cron

> Catatan: ini fokus ke **panel & web app**. Backup **data server game** (world/plugins) biasanya ditangani tools lain di Wings/node.

<p align="right">(<a href="#readme-top">back to top</a>)</p>



### What This Backs Up

Output default:

Isi yang dihasilkan (tergantung COMPRESS):
- `pterodactyl_panel_files.tar.zst` / `.tar.gz`
- `pterodactyl_panel_db.sql.zst` / `.sql.gz`
- `ctrlpanel_files.tar.zst` / `.tar.gz`
- `ctrlpanel_db.sql.zst` / `.sql.gz`
- `system_configs.tar.zst` / `.tar.gz`
- checksum `SHA256SUMS`

**Dibackup:**
- Pterodactyl: `/var/www/pterodactyl` + DB dari `.env`
- CtrlPanel: `/var/www/ctrlpanel` + DB dari `.env`
- Nginx: `/etc/nginx`
- SSL: `/etc/letsencrypt`
- Pterodactyl config: `/etc/pterodactyl`
- systemd + cron: `/etc/systemd/system`, `/etc/crontab`, `/var/spool/cron/crontabs`

**Tidak dibackup (by design):**
- data server game di Wings (mis. `/var/lib/pterodactyl/volumes`) — gunakan tools khusus backup server game.

<p align="right">(<a href="#readme-top">back to top</a>)</p>



### Built With

* [![Bash][Bash-shield]][Bash-url]
* [![rclone][rclone-shield]][rclone-url]
* [![zstd][zstd-shield]][zstd-url]
* [![jq][jq-shield]][jq-url]
* [![cron][cron-shield]][cron-url]

<p align="right">(<a href="#readme-top">back to top</a>)</p>



<!-- GETTING STARTED -->
## Getting Started

Ikuti langkah ini di VPS kamu (Ubuntu/Debian recommended).

### Prerequisites
Installation:
```sh
apt update
apt install -y jq curl tar gzip pigz zstd rsync mariadb-client postgresql-client util-linux coreutils
curl https://rclone.org/install.sh | bash

git clone https://github.com/YOUR_USERNAME/YOUR_REPO.git
cd YOUR_REPO

mkdir -p /opt/segeng-backup
cp backup-full.sh /opt/segeng-backup/
cp backup.conf /opt/segeng-backup/
chmod +x /opt/segeng-backup/backup-full.sh
chmod 600 /opt/segeng-backup/backup.conf

nano /opt/segeng-backup/backup.conf


