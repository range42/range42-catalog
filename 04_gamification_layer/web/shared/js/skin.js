/* Simple skin switcher per framework. Expects a <link id="skin-css"> pointing at ./skins/<skin>/skin.css */
(function(){
  function setSkin(skin){
    const link = document.getElementById('skin-css');
    if (!link) return;
    link.href = `./skins/${skin}/skin.css`;
    localStorage.setItem('skin', skin);
  }
  function initSkin(defaultSkin){
    const saved = localStorage.getItem('skin');
    const skin = saved || defaultSkin || 'classic';
    setSkin(skin);
    return skin;
  }
  window.SKIN = { set: setSkin, init: initSkin };
})();
