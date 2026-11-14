async function refreshPopup() {
  const dot = document.getElementById("dot");
  const bridgeStatus = document.getElementById("bridgeStatus");
  const domainEl = document.getElementById("domain");
  const errorRow = document.getElementById("errorRow");

  try {
    const status = await chrome.runtime.sendMessage({ type: "getStatus" });
    if (!status || !status.bridgeConnected) {
      dot.className = "dot err";
      bridgeStatus.textContent = "Native Bridge не подключён (установите мост в Keyboop → Настройки → Сайты)";
      errorRow.hidden = !status?.lastError;
      errorRow.textContent = status?.lastError ? `Детали: ${status.lastError}` : "";
    } else if (!status.keyboopConnected) {
      dot.className = "dot warn";
      bridgeStatus.textContent = "Мост активен, ожидание Keyboop.app";
      errorRow.hidden = true;
    } else {
      dot.className = "dot ok";
      bridgeStatus.textContent = "Подключено к Keyboop";
      errorRow.hidden = true;
    }

    if (status?.incognito) {
      domainEl.textContent = "инкогнито (передача по опции)";
    } else if (status?.internal) {
      domainEl.textContent = "служебная страница";
    } else if (status?.domain) {
      domainEl.textContent = status.domain;
    } else {
      domainEl.textContent = "—";
    }
  } catch (err) {
    dot.className = "dot err";
    bridgeStatus.textContent = "Ошибка опроса service worker";
    errorRow.hidden = false;
    errorRow.textContent = String(err);
  }
}

document.addEventListener("DOMContentLoaded", refreshPopup);
