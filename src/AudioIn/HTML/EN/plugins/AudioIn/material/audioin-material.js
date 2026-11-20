/**
 * AudioIn: stavka "Audio In" na Material Skin pocetnoj strani.
 * Ucitava je custom.js koji postavlja plugin AudioIn. Klik otvara stranicu plugina u
 * Material-ovom iframe dijalogu (isti put kao Extras stavke: dlg.open "iframe").
 * Sve je u jednoj funkciji, da ne dira globalne nazive drugih skripti.
 */
(function () {
    'use strict';

    var AUDIOIN_PAGE = "/plugins/AudioIn/index.html";
    var AUDIOIN_TITLE = "Audio In";
    var WAIT_MS = 200;
    var WAIT_LIMIT = 300;

    function globalType(name) {
        try {
            return (0, eval)("typeof " + name);
        } catch (e) {
            return "undefined";
        }
    }

    function missingGlobals() {
        return ["bus", "app", "TOP_ID_PREFIX"].filter(function (name) { return "undefined" == globalType(name); });
    }

    function itemId() {
        return TOP_ID_PREFIX + "audioin";
    }

    // Material otvara "extra" stavke u iframe dijalogu: bus.$emit("dlg.open", "iframe", url + "player=<id>", naslov, ...)
    function topItem() {
        return { id: itemId(), title: AUDIOIN_TITLE, icon: "graphic_eq", type: "extra", url: AUDIOIN_PAGE + "?", weight: 97 };
    }

    function showOnHome(view) {
        if (!view.top.some(function (i) { return i.id == itemId(); })) {
            view.top.push(topItem());
        }
        if (view.isTop && view.history.length < 1) {
            view.items = view.topExtra && view.$store.state.detailedHomeItems.length > 0 && view.grid.use ? view.topExtra.concat(view.top) : view.top;
            view.layoutGrid(true);
        }
    }

    // Nasa stavka se ne snima u korisnikov spisak pocetne strane.
    function patchView(view) {
        if (view.audioinPatched) {
            return;
        }
        view.audioinPatched = true;
        var originalSave = view.saveTopList;
        view.saveTopList = function () {
            var all = view.top;
            view.top = all.filter(function (i) { return i.id != itemId(); });
            originalSave.call(view);
            view.top = all;
        };
    }

    function attach(view) {
        patchView(view);
        showOnHome(view);
    }

    function findBrowseView(vm) {
        if (vm.initItems && vm.top) {
            return vm;
        }
        for (var i = 0; i < vm.$children.length; ++i) {
            var found = findBrowseView(vm.$children[i]);
            if (found) {
                return found;
            }
        }
        return undefined;
    }

    // Za ostale skripte i konzolu: otvara stranicu direktno.
    window.audioinOpen = function () {
        bus.$emit("dlg.open", "iframe", AUDIOIN_PAGE, AUDIOIN_TITLE);
    };

    function safeAttach(view) {
        try {
            attach(view);
        } catch (e) {
            console.warn("AudioIn: could not add the Audio CD item", e);
        }
    }

    function install() {
        if (window.audioinMaterialInstalled) {
            return;
        }
        window.audioinMaterialInstalled = true;
        bus.$on("homeScreenItems", function (view) {
            if (view.initItems && view.top) {
                safeAttach(view);
            }
        });
        var view;
        try {
            view = findBrowseView(app);
        } catch (e) {
            console.warn("AudioIn: Material view not found", e);
        }
        if (view) {
            safeAttach(view);
        }
    }

    function waitForMaterial(attempt) {
        var missing = missingGlobals();
        if (0 == missing.length) {
            install();
        } else if (attempt < WAIT_LIMIT) {
            setTimeout(function () { waitForMaterial(attempt + 1); }, WAIT_MS);
        } else {
            console.warn("AudioIn: Material Skin changed, the Audio CD item is disabled. Missing: " + missing.join(", "));
        }
    }

    waitForMaterial(0);
})();
