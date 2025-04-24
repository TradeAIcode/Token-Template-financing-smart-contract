
# 📘 Parámetros del Contrato – Explicación Detallada

Esta sección explica los parámetros que debes proporcionar al desplegar el contrato de financiamiento de tokens (Token Financing Template). Cada uno es crucial para el correcto funcionamiento, transparencia y seguridad del token.

---

## 🧾 tokenName (string memory)
**Explicación:** Nombre completo y legible del token, visible en wallets y plataformas como CoinMarketCap/CoinGecko.  
**Recomendación:** Debe ser descriptivo. Ej: `"Jarvi Financing Token"`, `"Proyecto Jarvi"`.

---

## 🏷️ tokenSymbol (string memory)
**Explicación:** Símbolo corto del token, usado como "ticker".  
**Recomendación:** 3–5 letras mayúsculas, únicas. Ej: `"JARVI"`, `"JFT"`.

---

## 🔢 tokenDecimals (uint8)
**Explicación:** Define en cuántas unidades se divide cada token.  
**Recomendación:** Usa `18` para máxima compatibilidad. Alternativas: `9`, `6` en casos específicos.

---

## 💰 initialSupply (uint256)
**Explicación:** Suministro inicial sin contar los decimales.  
**Recomendación:**  
- 1 millón = `1000000`  
- 100 millones = `100000000`  
- 1 billón = `1000000000`  
Será multiplicado por `10^decimals`.

---

## 🎁 reflectionFeePercent (uint256)
**Explicación:** Porcentaje redistribuido a los holders en cada transacción.  
**Recomendación:** Usa `1` a `5`. Ej: `2` para un 2%.

---

## 🌊 liquidityFeePercent (uint256)
**Explicación:** Porcentaje destinado al contrato para auto-liquidez.  
**Recomendación:** Comúnmente `1` a `5`. Ej: `3` para 3%.

---

## 🧠 devFeePercent (uint256)
**Explicación:** Porcentaje destinado a desarrollo/marketing/operaciones (dividido entre 3 carteras).  
**Recomendación:** De `0.5%` a `4%`. Ej: `1`.

> ⚠️ La suma total de `reflectionFeePercent + liquidityFeePercent + devFeePercent` **no debe superar 25%** (2500 BPS).

---

## 🔗 routerAddress (address)
**Explicación:** Dirección del Router V2 de Uniswap o DEX equivalente según la red.  
**Recomendación:**  
- Ejemplo: Uniswap V2 (Ethereum): `0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D` (¡verifica primero!)
- Critico: si está mal, fallará el sistema de liquidez.

---

## 🛠 initialDevWallet (address)
**Explicación:** Wallet que recibe 1/3 de la `devFee`.  
**Recomendación:** Multisig segura del equipo.

---

## 💧 initialLiqWallet (address)
**Explicación:** Wallet asociada a la tasa de liquidez (aunque los fondos se quedan en el contrato).  
**Recomendación:** Dirección del equipo o `address(this)`.

---

## 📣 initialMkWallet (address)
**Explicación:** Wallet que recibe 1/3 de la `devFee` para marketing.  
**Recomendación:** Multisig segura del proyecto.

---

## 🌍 initialChaWallet (address)
**Explicación:** Wallet que recibe 1/3 de la `devFee` para caridad/reserva.  
**Recomendación:** Multisig del equipo o contrato específico.

---

## 🧑‍💼 tokenOwner (address)
**Explicación:** Dueño del contrato y receptor de todo el `initialSupply`. Controla funciones `onlyOwner`.  
**Recomendación:** **Usar una Multisig + Timelock**. Nunca una EOA personal.

---

## ✅ Recomendaciones Finales

- Usa `18` decimales salvo que tengas razones técnicas.
- La suma de las tasas no debe pasar del `25%`.
- Verifica cuidadosamente la dirección del Router para tu red.
- Usa billeteras seguras (multifirma) para `tokenOwner` y todas las wallets de tasas.
