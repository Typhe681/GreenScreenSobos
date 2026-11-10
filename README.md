# GreenScreenSobos
A Sobosuba mod that replaces the sobo background colors with a media file.
It uses shaders to create a sort of chroma key effect.

Tested on Sobosuba v1.3.11


## Installation:
Use [Sobosuba Mod Manager](https://github.com/T0y-9n/sobosuba-mods), or do the following:

Extract `greenscreensobos.zip` from the [latest release](https://github.com/Typhe681/GreenScreenSobos/releases/latest) into Sobosuba's userdata folder

* **Windows:** `%APPDATA%\Godot\app_userdata\sobosuba`
* **Linux:** `~/.local/share/godot/app_userdata/sobosuba`


It should look like this:
```
├── styles
|   └── greenscreen_bootstrap.tres
└── greenscreensobos
    ├── greenScreen.gd
    └── <your media files here>
```


## Additional Files:
Within the greenscreensobos folder, you can place media files that you wish for the mod to use (there is a button in settings to easily open it).

If multiple files are placed in the folder, it will randomly choose one.

### Supported file types:
- .png
- .jpg
- .ogv
