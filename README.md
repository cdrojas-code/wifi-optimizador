# WiFi Optimizador

Herramienta para Windows 10/11 que diagnostica y corrige los problemas más comunes del WiFi:
cortes, pérdida de paquetes, drivers viejos, ahorro de energía e interferencia.
Funciona con cualquier tarjeta (Intel, Realtek, TP-Link, MediaTek…) y en Windows en español o inglés.

## Descarga

**[⬇️ Descargar la última versión](https://github.com/cdrojas-code/wifi-optimizador/releases/latest)**: baja el archivo `WifiOptimizador-vX.Y.Z.zip` y descomprímelo.

## Uso rápido

Doble clic en **`Iniciar.bat`** y elige una opción del menú:

| Opción | Qué hace | ¿Cambia algo? |
|---|---|---|
| 1. Diagnosticar | Revisa todo y genera un reporte HTML en `reportes\` | No |
| 2. Optimizar | Guarda un respaldo y aplica las mejoras, preguntando antes de cada una | Sí (pide administrador) |
| 3. Simular | Muestra qué cambiaría Optimizar, sin tocar nada | No |
| 4. Restaurar | Vuelve a la configuración del último respaldo | Sí (pide administrador) |

## Desde PowerShell

```powershell
.\WifiOptimizador.ps1 -Modo Diagnosticar
.\WifiOptimizador.ps1 -Modo Optimizar -Simular
.\WifiOptimizador.ps1 -Modo Optimizar
.\WifiOptimizador.ps1 -Modo Optimizar -Forzar -SinDrivers   # sin preguntas y sin Windows Update
.\WifiOptimizador.ps1 -Modo Restaurar -Respaldo .\respaldos\respaldo-PC-20260101-120000.json
.\WifiOptimizador.ps1 -Modo Diagnosticar -Adaptador "Intel"  # solo un adaptador
```

## Qué revisa el diagnóstico

- Adaptadores WiFi: deshabilitados, tipo (interno/USB), antigüedad del driver.
- Señal, banda (2,4/5 GHz), canal y velocidad de la conexión actual.
- Si tu red está disponible en 5 GHz y estás conectado en 2,4 GHz.
- Interferencia en 2,4 GHz y el canal menos ocupado (1, 6 u 11) para configurar en el router.
- Pérdida de paquetes y latencia hacia el router y hacia internet; DNS y navegación.
- Caídas reales en las últimas 24 h (separa las del driver de las manuales o por reinicio).
- Ahorro de energía: apagado del adaptador, plan de energía y suspensión selectiva USB.
- Drivers WiFi nuevos disponibles en Windows Update.

## Qué puede cambiar el modo Optimizar

Siempre pregunta antes (salvo con `-Forzar`) y solo cambia lo que hace falta:

1. Habilitar adaptadores WiFi deshabilitados.
2. Instalar drivers WiFi oficiales desde Windows Update.
3. Itinerancia al mínimo, ancho de canal de 2,4 GHz en 20 MHz, ahorro MIMO desactivado.
4. Preferir 5 GHz (solo si tu red está disponible en 5 GHz con buena señal).
5. Impedir que Windows apague el adaptador para ahorrar energía.
6. Plan de energía: WiFi en rendimiento máximo; suspensión selectiva USB desactivada si hay un adaptador USB.

## Respaldo y restauración

Antes de cambiar nada guarda la configuración en `respaldos\respaldo-<EQUIPO>-<fecha>.json`.
El modo Restaurar la vuelve a aplicar.
**Los drivers no se revierten con Restaurar**: para eso usa *Revertir al controlador anterior*
en el Administrador de dispositivos.

## Notas

- Para ver la señal y las redes cercanas, Windows exige el permiso de **ubicación**: activa
  "Servicios de ubicación", "Permitir que las aplicaciones accedan a la ubicación" y
  "Permitir que las aplicaciones de escritorio accedan a la ubicación". El diagnóstico te avisa y abre la configuración.
- Cada ejecución deja un log en `logs\`.
- Los reportes incluyen nombres de redes vecinas y el nombre del equipo: tenlo en cuenta antes de compartirlos.
