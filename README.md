# Service PC Glew - Windows Utility 🛠️

[![Version](https://img.shields.io/github/v/release/ServicePCGlew/winutil?color=%230567ff&label=Latest%20Release&style=for-the-badge)](https://github.com/servicepcglew/winutil/releases/latest)
![GitHub Downloads](https://img.shields.io/github/downloads/ServicePCGlew/winutil/winutil.ps1?label=Total%20Downloads&style=for-the-badge)
[![Static Badge](https://img.shields.io/badge/Documentation-_?style=for-the-badge&logo=bookstack&color=grey)](https://servicepcglew-winutil.pages.dev/)

*[English version below](#english-version)*

Esta es la utilidad de mantenimiento, optimización y configuración de Windows personalizada y mantenida por **Service PC Glew**. 

Esta herramienta está diseñada para agilizar la instalación de programas, optimizar el sistema eliminando software innecesario (debloat), ajustar configuraciones para mejorar el rendimiento general y solucionar problemas comunes de Windows.

![screen-install](/docs/assets/images/Title-Screen.png)

## 💡 Uso (Español)

La utilidad debe ejecutarse con permisos de Administrador, ya que realiza ajustes profundos en el sistema operativo.

1. Haz clic derecho en el menú de Inicio.
2. Selecciona **"Windows PowerShell (Administrador)"** o **"Terminal (Administrador)"** (en Windows 11).

### Comando de lanzamiento

Una vez en la consola, copia y pega el siguiente comando:

**Versión Estable (Recomendada):**
```ps1
irm "https://servicepcglew-winutil.pages.dev/winutil.ps1" | iex
```

**Versión de Desarrollo:**
```ps1
irm "https://servicepcglew-winutil.pages.dev/winutil.ps1dev" | iex
```

---

<a id="english-version"></a>
## 💡 Usage (English)

This utility is a compilation of Windows tasks to streamline installs, debloat with tweaks, troubleshoot with config, and fix Windows updates. Maintained by **Service PC Glew**.

Winutil must be run in Admin mode because it performs system-wide tweaks. Open PowerShell as an administrator and run the following command:

**Stable Branch (Recommended):**
```ps1
irm "https://servicepcglew-winutil.pages.dev/winutil.ps1" | iex
```

**Dev Branch:**
```ps1
irm "https://servicepcglew-winutil.pages.dev/winutil.ps1dev" | iex
```

---

## 🛠️ Build & Develop / Desarrollo

> [!NOTE]  
> Este script es extenso, por lo que está dividido en múltiples archivos que se combinan en un único `.ps1` usando un script compilador personalizado (`Compile.ps1`).

Para compilar tu propia versión localmente:

```ps1
git clone --depth 1 "https://github.com/servicepcglew/winutil.git"
cd winutil
.\Compile.ps1
```

Esto generará el archivo unificado `winutil.ps1` listo para ser ejecutado.

## 🤝 Soporte / Support

- 🐛 [Reportar un problema (Issues)](https://github.com/servicepcglew/winutil/issues)
- 📖 [Documentación Oficial](https://servicepcglew-winutil.pages.dev/)

Si esta herramienta te ha sido de utilidad, ¡no olvides apoyar el proyecto dejándole una ⭐️ en GitHub!
