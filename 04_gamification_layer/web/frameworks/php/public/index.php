<!doctype html>
<html>
<head>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1"/>
  <title>Range42 – PHP</title>
  <link rel="stylesheet" href="../../../shared/css/design-system.css">
  <link id="skin-css" rel="stylesheet" href="./skins/classic/skin.css">
  <script>window.APP_SHARED_BASE = "../../../shared";</script>
  <script src="../../../shared/js/i18n.js"></script>
  <script src="../../../shared/js/skin.js"></script>
</head>
<body>
  <div class="container">
    <header class="header">
      <?php include __DIR__ . '/../templates/partials/header.php'; ?>
      <div class="controls">
        <label><span data-i18n="controls.language">Language</span>:
          <select id="lang">
            <option value="en">EN</option>
            <option value="de">DE</option>
          </select>
        </label>
        <label><span data-i18n="controls.skin">Skin</span>:
          <select id="skin">
            <option value="classic">Classic</option>
            <option value="hospital">Hospital</option>
          </select>
        </label>
      </div>
    </header>

    <?php include __DIR__ . '/../templates/partials/nav.php'; ?>

    <main class="panel">
      <h2 class="hero" data-i18n="content.welcome">Welcome challenger! Pick a skin and language.</h2>
      <p data-i18n="content.about">This is a simple, swappable UI used across challenges.</p>
    </main>

    <?php include __DIR__ . '/../templates/partials/footer.php'; ?>
  </div>

  <script>
    (async function(){
      const langSel = document.getElementById('lang');
      const skinSel = document.getElementById('skin');
      langSel.value = localStorage.getItem('lang') || 'en';
      skinSel.value = SKIN.init('classic');
      await I18N.load(langSel.value);
      langSel.addEventListener('change', async (e)=>{ await I18N.load(e.target.value); });
      skinSel.addEventListener('change', (e)=>{ SKIN.set(e.target.value); });
    })();
  </script>
</body>
</html>
