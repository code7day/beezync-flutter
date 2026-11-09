# beezync_sdk (Dart / Flutter)

Cliente de Beezync para Dart y Flutter. Es Dart puro: solo depende de `http` y `web_socket_channel`. El token de push lo obtiene la app con `firebase_messaging`; el SDK no incluye plugins de plataforma.

Sigue la especificación común de `Api-Service/docs/SDK_SPEC.md`.

## Instalación

```sh
flutter pub add beezync_sdk
```

O agrégalo a tu `pubspec.yaml`:

```yaml
dependencies:
  beezync_sdk: ^0.1.0
```

Luego `flutter pub get`.

## Uso

```dart
import 'package:beezync_sdk/beezync_sdk.dart';

final bz = Beezync(const BeezyncConfig(
  appId: '00000000-0000-0000-0000-000000000000',
  publicKey: 'pk_...',          // nunca la llave secreta
  baseUrl: 'https://api.beezync.com',
));

// Dispositivo (token FCM obtenido con firebase_messaging)
final r = await bz.registerDevice(
  token: fcmToken,
  platform: 'android',          // 'ios' en iPhone
  externalUserId: 'user-42',
  tags: {'plan': 'pro'},
);
if (!r.ok) print(r.error);

await bz.setUser('user-43');
await bz.setTags({'lang': 'es'});
await bz.unregisterDevice();

// Tiempo real
bz.onMessage((m) => print('${m.event} ${m.channel} ${m.data}'));
bz.subscribe('news');                         // público
bz.subscribe('private-room', auth: hexAuth);  // privado: auth o token del servidor propio
bz.connect();
// ...
await bz.disconnect();

// Recibos y clics
await bz.trackReceived(id);
await bz.trackClicked(id);
await bz.trackDismissed(id);
```

Con un mensaje de FCM (`RemoteMessage`) basta pasar su mapa `data`:

```dart
FirebaseMessaging.onMessage.listen((m) => bz.trackReceivedFromData(m.data));
FirebaseMessaging.onMessageOpenedApp.listen((m) => bz.trackClickedFromData(m.data));
final id = bzIdFromData(message.data); // String? con el bz_id
```

### Resultados y errores

Ninguna operación HTTP lanza excepciones: devuelven `BeezyncResult` (`ok`, `statusCode`, `error`, `body`). Si falla la red, `error` empieza por `network` o vale `timeout`. `setUser`, `setTags`, `unregisterDevice` y los `track*` usan el token guardado tras `registerDevice`; si no hay, devuelven `error: 'no_token'`. Si el push no trae `bz_id`, las variantes `*FromData` devuelven `no_bz_id`.

### Streams

| Miembro | Contenido |
|---|---|
| `messages` / `onMessage` | `BeezyncMessage`: publicaciones (`event`, `channel`, `data`, `id`, `ts`) y notificaciones por socket (`title`, `body`, `data`; `isNotification == true`) |
| `connectionState` | `disconnected`, `connecting`, `connected` |
| `subscriptionEvents` | resultado de cada suscripción (`ok` o `error`) |

### Reconexión

- Espera exponencial de 1 s a 30 s con variación aleatoria (±20 %). El contador se reinicia al recibir `connection_established`.
- Tras reconectar se vuelven a enviar todas las suscripciones activas con su `auth` o `token`. Si el `auth` de un canal privado depende del `socket_id`, renuévalo y llama de nuevo `subscribe` cuando `socketId` cambie.
- El código de cierre `4200` reconecta de inmediato, sin espera.
- `disconnect()` detiene la reconexión. Se envía `ping` cada 25 s (`BeezyncConfig.pingInterval`, `null` lo desactiva).

## Configuración de Firebase

El push lo entrega FCM en ambas plataformas (en iOS, FCM usa APNs). Se hace una vez por proyecto de Firebase.

1. En la [consola de Firebase](https://console.firebase.google.com) crea un proyecto y añade las apps Android e iOS con los mismos identificadores que tu proyecto Flutter (`applicationId` y Bundle ID).
2. Instala las herramientas y enlaza Flutter:
   ```bash
   dart pub global activate flutterfire_cli
   npm install -g firebase-tools && firebase login
   flutterfire configure
   ```
   Esto genera `lib/firebase_options.dart` (y los archivos nativos). La app llama `Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform)`.
3. Dependencias de la app: `firebase_core` y `firebase_messaging`.
4. En Beezync, carga las credenciales de servicio de FCM de tu proyecto (cuenta de servicio con permiso de envío) en la configuración de la app.

### Android

- `minSdk` 21 o superior. En Android 13+ el permiso de notificaciones se pide en tiempo de ejecución (`FirebaseMessaging.instance.requestPermission()`).
- Los mensajes con carga `notification` los muestra el sistema cuando la app está en segundo plano; la apertura llega por `onMessageOpenedApp` o `getInitialMessage()`.

### iOS

1. Requiere una cuenta de Apple Developer y un iPhone físico (el simulador no recibe push remoto).
2. En [developer.apple.com](https://developer.apple.com/account/resources/authkeys/list) crea una llave **APNs Auth Key** (`.p8`) y anota el Key ID y tu Team ID.
3. En Firebase: Configuración del proyecto, Cloud Messaging, Apple app configuration, **APNs Authentication Key**, sube el `.p8` con Key ID y Team ID.
4. En Xcode (`ios/Runner.xcworkspace`), target Runner, Signing & Capabilities: añade **Push Notifications** y **Background Modes** con *Remote notifications*.
5. Ejecuta `cd ios && pod install` si hace falta, y prueba en el dispositivo real.

## Pruebas

```bash
dart pub get
dart analyze
dart test
```

La prueba de integración se omite salvo que se defina el entorno (la llave secreta solo se lee del entorno, nunca se guarda en archivos):

```bash
BEEZYNC_INTEGRATION=1 BASE_URL=http://127.0.0.1:8099 APP_ID=... PUBLIC_KEY=pk_... SECRET_KEY=sk_... \
  dart test test/integration_test.dart
```

Registra un dispositivo, conecta, publica, envía un push por `ws`, reporta recibido y clic, y comprueba los contadores con `GET /v1/api/notifications/{id}`.

## Autoría y licencia

Beezync es un proyecto de Eduardo Flores. El servicio comercial de Beezync es respaldado y operado por ITM Soluciones Tecnológicas e Inversiones S.A.C. Este SDK se distribuye con licencia MIT (ver `LICENSE`).
