<h1 align="center">🚀 BEST-AI: Local AI Server Setup</h1>

<p align="center">
<img src="https://img.shields.io/github/stars/toprakahmetaydogmus/BEST-AI?style=for-the-badge&color=gold" alt="GitHub Stars">
<img src="https://img.shields.io/github/forks/toprakahmetaydogmus/BEST-AI?style=for-the-badge&color=blue" alt="GitHub Forks">
<img src="https://img.shields.io/badge/License-MIT-green.svg?style=for-the-badge" alt="License">


<img src="https://img.shields.io/badge/Windows-10%2F11-blue?style=for-the-badge&logo=windows&logoColor=white" alt="Windows Supported">
<img src="https://img.shields.io/badge/Security-1%2F72%20Clean-brightgreen?style=for-the-badge&logo=virustotal&logoColor=white" alt="Security Scan">
<img src="https://img.shields.io/badge/Winget-PR%20%23355179-orange?style=for-the-badge&logo=microsoft&logoColor=white" alt="Winget PR Status">
</p>

Professional automated solution for deploying, managing, and exposing local Large Language Models (LLMs) with Ollama.
Developed by Toprak Ahmet Aydoğmuş under Siber Akademi.

🌟 Overview
BEST-AI v3.0 transforms your local machine into a high-performance AI hub in minutes. It automates the tedious setup of drivers, network tunneling, and web interfaces, providing a secure, local-first alternative to cloud AI providers.

✨ Key Features
🛡️ Core Infrastructure
Zero-Config Deployment: Automatic installation of Ollama on Windows (via Winget) and Linux.

Hardware Acceleration: Native detection and configuration for NVIDIA CUDA and AMD ROCm.

Resource Analysis: Real-time monitoring of RAM, Disk, and CPU availability.

🌐 Connectivity & Security
Global Access: One-click deployment of Cloudflare Tunnels or ngrok to access your local AI from anywhere in the world.

Caddy Reverse Proxy: High-performance web server integration for secure API handling.

Security First: Mandatory X-API-Key protection for all remote access scenarios.

🎨 Modern Web Experience
Dark/Neon UI: A futuristic Matrix-inspired web interface with built-in Markdown support and syntax highlighting.

Multimodal Ready: Support for text input, file uploads, and Voice Recognition (STT).

Streaming: Real-time response streaming for a ChatGPT-like experience.

🛠️ Technical Menu / Usage
FAST START: Installs/Starts all services using existing configurations.

FULL SETUP: Complete step-by-step hardware analysis, network config, and model selection.

MODEL MANAGEMENT: Specialized downloader for Llama 3.2, Qwen 2.5, DeepSeek R1, Phi-4, and more.

BENCHMARK: Performance testing to measure your system's tokens per second (TPS).

🚀 Quick Start
Run the following command in an Administrative PowerShell:

PowerShell
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://raw.githubusercontent.com/toprakahmetaydogmus/BEST-AI/main/bestai.ps1'))
Or download the latest compiled installer from Releases.

🛡️ Security & Trust Verification
Criteria	Status	Description
Packaging	Inno Setup	Compiled Professional Installer Aligned with Winget Policies
Digital Signature	Siber Akademi	Authenticode Signed & Verified for Code Integrity
Antivirus Scan	Verified	1/72 Clean on VirusTotal
Code Integrity	SHA-256	DD6443D0812D9B410B2A38E77AD9C9E816BB346146D6F7559414BB83BB042A02
Developer Note: This application is digitally signed by Siber Akademi. If Windows shows an "Unknown Publisher" warning, it is due to the self-signed nature of the development certificate. The file is 100% safe, verified, and its integrity is guaranteed by the signature.

🗂️ Data Architecture
The setup centralizes everything in ai_server_data:

/web: Modern HTML5 UI & Caddyfile configuration.

/logs: Comprehensive logs for troubleshooting.

/backups: Automated configuration backups.

config.json: Master server & network state.

👤 Developer & Support
<p align="center">
<a href="https://hopp.bio/siberegitim">
<img src="https://img.shields.io/badge/Developed%20By-Toprak%20Ahmet%20Aydo%C4%9Fmu%C5%9F-blueviolet?style=for-the-badge" alt="Lead Developer">
</a>
</p>
<p align="center">
<a href="https://hopp.bio/siberegitim">
<img src="https://img.shields.io/badge/Organization-Siber%20Akademi-lightgrey?style=for-the-badge&logo=opsgenie" alt="Company">
</a>
</p>
<p align="center">
<a href="https://github.com/toprakahmetaydogmus/BEST-AI/issues">
<img src="https://img.shields.io/github/issues/toprakahmetaydogmus/BEST-AI?style=for-the-badge" alt="Issues">
</a>
<a href="https://github.com/toprakahmetaydogmus/BEST-AI/pulls">
<img src="https://img.shields.io/github/issues-pr/toprakahmetaydogmus/BEST-AI?style=for-the-badge" alt="Pull Requests">
</a>
</p>

📝 License
This project is licensed under the MIT License - see the LICENSE file for details.
