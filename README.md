# ScreenSnip
A minimalist tool for floating temporary screen snips.

This is based on Snipper by FanaticGuru, and has a subset of the features, with a couple of different features added. The features that I mostly need with this type of utility are: Transparency; ability to flip; and rarely, ability to rotate. Those are the features that were added to the first version. Later, support for OCRing tables was added. The SnipOCR.ahk code reconstructs the table parts. It does a pretty good job of scanning tables that contain a mixture of digits and wrapped text. Post-snip pan/resize idea from @alnz123.  Has been tested (successfully) on Win 11. Thanks Niek!

`Ctrl`+`RClick`-and-drag to select. Then, with the snip selected, press `F1` for a list of the hotkeys.

(On-screen keyboard is a separate ahk app... Not part of ScreenSnip.ahk.)
![Screenshot of ScreenSnip](https://i.imgur.com/W0s9cmA.gif)

A gif, showing a table snip.
*You can see that it is not perfect (puts the 4s in a separate column), but it is pretty good. Handles wrapped text well. Oddly, the fourth row does not get pasted into Excel. It is indeed on the clipboard though...
![Screenshot of ScreenSnip table OCR](https://github.com/kunkel321/ScreenSnip/blob/main/ScreenSnipOCRDemo.gif)

AHK Forum https://www.autohotkey.com/boards/viewtopic.php?f=83&t=140802
