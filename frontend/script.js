/* ==========================================================
   NEXVION STORE — MAIN FRONTEND JAVASCRIPT
   Fetches products from backend API, cart/auth via localStorage.
========================================================== */

const API_BASE = "/api";

const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => document.querySelectorAll(selector);

let products = [];
let categories = ["All"];

function money(value) {
  return new Intl.NumberFormat("en-IN", {
    style: "currency",
    currency: "INR",
    maximumFractionDigits: 0
  }).format(Number(value) || 0);
}

function escapeHTML(value) {
  return String(value)
    .replaceAll("&", "&")
    .replaceAll("<", "<")
    .replaceAll(">", ">")
    .replaceAll('"', "\"")
    .replaceAll("'", "&#039;");
}

function toast(message) {
  const box = $("#toast");
  if (!box) return;
  box.textContent = message;
  box.classList.add("show");
  clearTimeout(window.__toastTimer);
  window.__toastTimer = setTimeout(() => box.classList.remove("show"), 2300);
}

async function fetchProducts(params = {}) {
  const searchParams = new URLSearchParams();
  Object.entries(params).forEach(([k, v]) => {
    if (v !== undefined && v !== null && v !== "") searchParams.set(k, v);
  });
  const res = await fetch(`${API_BASE}/products?${searchParams}`);
  if (!res.ok) throw new Error("Failed to fetch products");
  return res.json();
}

async function fetchCategories() {
  const res = await fetch(`${API_BASE}/products/categories`);
  if (!res.ok) throw new Error("Failed to fetch categories");
  return res.json();
}

async function loadProducts() {
  try {
    console.log("Loading products...");
    const data = await fetchProducts({
      category: selectedCategory !== "All" ? selectedCategory : undefined,
      max_price: selectedPrice < 5000 ? selectedPrice : undefined,
      in_stock: onlyInStock || undefined,
      search: ($("#searchInput")?.value || "").trim() || undefined,
      sort: $("#sortProducts")?.value || "featured",
      page: 1,
      page_size: 100
    });
    products = data.products;
    console.log("Products loaded:", products.length);
    renderCategoryFilters();
    renderFeaturedProducts();
    // Only render shop products if we're on the shop page
    if ($("#shopProductGrid")) {
      renderShopProducts();
    }
  } catch (e) {
    console.error("Failed to load products:", e);
    toast("Failed to load products");
  }
}

async function loadCategories() {
  try {
    categories = await fetchCategories();
    console.log("Categories loaded:", categories);
    renderCategoryFilters();
  } catch (e) {
    console.error(e);
  }
}

/* --------------------------
   STORAGE / MIGRATION
-------------------------- */

function getJSON(key, fallback) {
  try {
    const value = localStorage.getItem(key);
    return value ? JSON.parse(value) : fallback;
  } catch {
    return fallback;
  }
}

let cart = getJSON("nexvionCart", getJSON("davineCart", []));
let users = getJSON("nexvionUsers", getJSON("davineUsers", []));
let currentUser = getJSON("nexvionCurrentUser", getJSON("davineCurrentUser", null));

function saveCart() { localStorage.setItem("nexvionCart", JSON.stringify(cart)); }
function saveUsers() { localStorage.setItem("nexvionUsers", JSON.stringify(users)); }
function saveCurrentUser() {
  if (currentUser) localStorage.setItem("nexvionCurrentUser", JSON.stringify(currentUser));
  else localStorage.removeItem("nexvionCurrentUser");
}

/* --------------------------
   AUTH
-------------------------- */

function renderAuth() {
  const area = $("#authArea");
  if (!area) return;
  if (currentUser) {
    const firstName = escapeHTML(currentUser.name.split(" ")[0]);
    area.innerHTML = `<button class="user-button" id="logoutButton">Hi, ${firstName} \u00b7 Logout</button>`;
    $("#logoutButton").addEventListener("click", logout);
  } else {
    area.innerHTML = `<button class="button button-dark" id="signInButton">Sign In</button>`;
    $("#signInButton").addEventListener("click", () => openAuth("login"));
  }
}

function openAuth(tab = "login") {
  const modal = $("#authModal");
  if (!modal) return;
  modal.classList.add("active");
  modal.setAttribute("aria-hidden", "false");
  document.body.classList.add("no-scroll");
  switchAuth(tab);
}

function closeAuth() {
  const modal = $("#authModal");
  if (!modal) return;
  modal.classList.remove("active");
  modal.setAttribute("aria-hidden", "true");
  document.body.classList.remove("no-scroll");
}

function switchAuth(tab) {
  $$(".auth-tab").forEach((b) => b.classList.toggle("active", b.dataset.authTab === tab));
  $("#loginForm")?.classList.toggle("hidden", tab !== "login");
  $("#registerForm")?.classList.toggle("hidden", tab !== "register");
}

function logout() {
  currentUser = null;
  saveCurrentUser();
  renderAuth();
  toast("You have been logged out.");
}

$$("[data-close-auth]").forEach((b) => b.addEventListener("click", closeAuth));
$$("[data-auth-tab]").forEach((b) => b.addEventListener("click", () => switchAuth(b.dataset.authTab)));
$$("[data-switch-auth]").forEach((b) => b.addEventListener("click", () => switchAuth(b.dataset.switchAuth)));

$("#registerForm")?.addEventListener("submit", (e) => {
  e.preventDefault();
  const name = $("#registerName").value.trim();
  const email = $("#registerEmail").value.trim().toLowerCase();
  const password = $("#registerPassword").value;
  const confirmPassword = $("#registerConfirmPassword").value;

  if (name.length < 2) return toast("Please enter your full name.");
  if (password.length < 6) return toast("Password must contain at least 6 characters.");
  if (password !== confirmPassword) return toast("Passwords do not match.");
  if (users.some((u) => u.email === email)) return toast("This email is already registered."), switchAuth("login"), $("#loginEmail").value = email;

  const user = { id: Date.now(), name, email, password };
  users.push(user);
  currentUser = user;
  saveUsers();
  saveCurrentUser();
  $("#registerForm").reset();
  closeAuth();
  renderAuth();
  toast("Account created successfully.");
});

$("#loginForm")?.addEventListener("submit", (e) => {
  e.preventDefault();
  const email = $("#loginEmail").value.trim().toLowerCase();
  const password = $("#loginPassword").value;
  const user = users.find((u) => u.email === email && u.password === password);
  if (!user) return toast("Invalid email or password.");
  currentUser = user;
  saveCurrentUser();
  $("#loginForm").reset();
  closeAuth();
  renderAuth();
  toast(`Welcome back, ${user.name.split(" ")[0]}!`);
});

/* --------------------------
   CART
-------------------------- */

function cartCount() { return cart.reduce((s, i) => s + Number(i.quantity || 0), 0); }

function cartTotal() {
  return cart.reduce((s, i) => {
    const p = products.find((p) => p.id === Number(i.id));
    return p ? s + p.price * Number(i.quantity || 0) : s;
  }, 0);
}

function updateCartCount() { const c = $("#cartCount"); if (c) c.textContent = cartCount(); }

function addToCart(id) {
  const product = products.find((p) => p.id === Number(id));
  if (!product) return;
  const existing = cart.find((i) => i.id === product.id);
  if (existing) existing.quantity += 1;
  else cart.push({ id: product.id, quantity: 1 });
  saveCart();
  renderCart();
  updateCartCount();
  toast(`${product.name} added to your bag.`);
}

function changeQuantity(id, amount) {
  const item = cart.find((i) => i.id === Number(id));
  if (!item) return;
  item.quantity += amount;
  if (item.quantity <= 0) cart = cart.filter((i) => i.id !== Number(id));
  saveCart();
  renderCart();
  updateCartCount();
}

function removeFromCart(id) {
  cart = cart.filter((i) => i.id !== Number(id));
  saveCart();
  renderCart();
  updateCartCount();
  toast("Product removed from your bag.");
}

function renderCart() {
  const container = $("#cartItems");
  if (!container) return;
  if (!cart.length) {
    container.innerHTML = `<div style="text-align:center;padding:55px 15px;color:#888;"><div style="font-size:38px;margin-bottom:12px;">\uD83D\uDED2</div><strong>Your bag is empty.</strong><p style="font-size:11px;margin-top:7px;">Add something you love from the shop.</p></div>`;
    if ($("#subtotal")) $("#subtotal").textContent = money(0);
    return;
  }
  container.innerHTML = cart.map((item) => {
    const product = products.find((p) => p.id === Number(item.id));
    if (!product) return "";
    return `<article class="cart-item"><img src="${product.image_url}" alt="${escapeHTML(product.name)}"><div><h4>${escapeHTML(product.name)}</h4><p>${money(product.price)}</p><div class="quantity"><button type="button" data-minus="${product.id}">\u2212</button><span>${item.quantity}</span><button type="button" data-plus="${product.id}">+</button></div></div><button type="button" class="remove-item" data-remove="${product.id}">Remove</button></article>`;
  }).join("");
  $("#subtotal").textContent = money(cartTotal());
  $$("[data-plus]").forEach((b) => b.addEventListener("click", () => changeQuantity(b.dataset.plus, 1)));
  $$("[data-minus]").forEach((b) => b.addEventListener("click", () => changeQuantity(b.dataset.minus, -1)));
  $$("[data-remove]").forEach((b) => b.addEventListener("click", () => removeFromCart(b.dataset.remove)));
}

function openCart() { $("#cartDrawer")?.classList.add("active"); $("#drawerOverlay")?.classList.add("active"); document.body.classList.add("no-scroll"); }
function closeCart() { $("#cartDrawer")?.classList.remove("active"); $("#drawerOverlay")?.classList.remove("active"); document.body.classList.remove("no-scroll"); }

$("#cartButton")?.addEventListener("click", openCart);
$("#closeCart")?.addEventListener("click", closeCart);
$("#drawerOverlay")?.addEventListener("click", closeCart);

/* --------------------------
   CHECKOUT
-------------------------- */

$("#checkoutButton")?.addEventListener("click", () => {
  if (!cart.length) return toast("Your bag is empty.");
  if (!currentUser) { closeCart(); openAuth("login"); return toast("Please sign in before checkout."); }
  const checkoutItems = cart.map((item) => {
    const product = products.find((p) => p.id === Number(item.id));
    if (!product) return null;
    return { id: product.id, name: product.name, category: product.category, price: product.price, image: product.image_url, quantity: Number(item.quantity) };
  }).filter(Boolean);
  localStorage.setItem("nexvionCheckout", JSON.stringify({ user: { id: currentUser.id, name: currentUser.name, email: currentUser.email }, items: checkoutItems, subtotal: cartTotal(), createdAt: Date.now() }));
  closeCart();
  window.location.href = "payment.html";
});

/* --------------------------
   PRODUCT CARD
-------------------------- */

function productCard(product, shop = false) {
  const imageClass = shop ? "shop-product-image" : "product-image";
  const cardClass = shop ? "shop-product-card" : "product-card";
  const infoClass = shop ? "shop-product-info" : "product-info";
  const categoryClass = shop ? "shop-product-category" : "product-category";
  const nameClass = shop ? "shop-product-name" : "product-name";
  const priceClass = shop ? "shop-product-price" : "product-price";
  const buttonClass = shop ? "shop-add-cart" : "add-cart";
  return `<article class="${cardClass}"><div class="${imageClass}"><img src="${product.image_url}" alt="${escapeHTML(product.name)}" loading="lazy" onerror="this.onerror=null;this.src='https://placehold.co/900x900/f1f1ef/222?text=NEXVION';"><span class="${shop ? "shop-product-tag" : "product-tag"}">${escapeHTML(product.tag || "")}</span><button type="button" class="${buttonClass}" data-add-cart="${product.id}" aria-label="Add ${escapeHTML(product.name)} to bag">+</button></div><div class="${infoClass}"><span class="${categoryClass}">${escapeHTML(product.category)}</span><h3 class="${nameClass}">${escapeHTML(product.name)}</h3><div class="${priceClass}">${money(product.price)}</div></div></article>`;
}

function bindAddButtons() { $$("[data-add-cart]").forEach((b) => b.addEventListener("click", () => addToCart(b.dataset.addCart))); }

function renderFeaturedProducts() {
  const grid = $("#featuredProducts");
  if (!grid) return;
  console.log("Rendering featured products, products count:", products.length);
  grid.innerHTML = products.slice(0, 4).map((p) => productCard(p)).join("");
  bindAddButtons();
}

/* --------------------------
   SHOP FILTERS
-------------------------- */

let selectedCategory = "All";
let selectedPrice = 5000;
let onlyInStock = false;

function renderCategoryFilters() {
  const box = $("#categoryFilters");
  if (!box) return;
  box.innerHTML = categories.map((category) => {
    const count = category === "All" ? products.length : products.filter((p) => p.category === category).length;
    return `<button type="button" class="category-filter ${selectedCategory === category ? "active" : ""}" data-category="${escapeHTML(category)}"><span>${escapeHTML(category)}</span><span>${count}</span></button>`;
  }).join("");
  $$("[data-category]").forEach((b) => b.addEventListener("click", () => { selectedCategory = b.dataset.category; renderCategoryFilters(); loadProducts(); }));
}

function renderShopProducts() {
  const grid = $("#shopProductGrid");
  if (!grid) return;
  grid.innerHTML = products.map((p) => productCard(p, true)).join("");
  bindAddButtons();
}

function loadCategoryFromURL() {
  const category = new URLSearchParams(window.location.search).get("category");
  if (category && categories.includes(category)) selectedCategory = category;
}

$("#priceRange")?.addEventListener("input", (e) => {
  selectedPrice = Number(e.target.value);
  $("#maxPriceLabel").textContent = selectedPrice >= 5000 ? "\u20B95,000+" : money(selectedPrice);
  loadProducts();
});

$("#inStock")?.addEventListener("change", (e) => { onlyInStock = e.target.checked; loadProducts(); });
$("#sortProducts")?.addEventListener("change", loadProducts);
$("#clearFilters")?.addEventListener("click", resetFilters);
$("#emptyClear")?.addEventListener("click", resetFilters);

function resetFilters() {
  selectedCategory = "All"; selectedPrice = 5000; onlyInStock = false;
  if ($("#priceRange")) $("#priceRange").value = "5000";
  if ($("#maxPriceLabel")) $("#maxPriceLabel").textContent = "\u20B95,000+";
  if ($("#inStock")) $("#inStock").checked = false;
  if ($("#sortProducts")) $("#sortProducts").value = "featured";
  if ($("#searchInput")) $("#searchInput").value = "";
  renderCategoryFilters();
  loadProducts();
}

$("#mobileFilterButton")?.addEventListener("click", () => $("#filters")?.classList.toggle("mobile-open"));

/* --------------------------
   SEARCH
-------------------------- */

$("#searchButton")?.addEventListener("click", () => { $("#searchOverlay")?.classList.add("active"); document.body.classList.add("no-scroll"); $("#searchInput")?.focus(); });
$("#closeSearch")?.addEventListener("click", closeSearch);

function closeSearch() {
  $("#searchOverlay")?.classList.remove("active");
  document.body.classList.remove("no-scroll");
  if ($("#searchInput")) $("#searchInput").value = "";
  if ($("#shopProductGrid")) loadProducts();
}

$("#searchInput")?.addEventListener("input", () => { if ($("#shopProductGrid")) loadProducts(); });

/* --------------------------
   MOBILE MENU
-------------------------- */

$("#mobileMenuButton")?.addEventListener("click", () => $("#mobileMenu")?.classList.toggle("active"));
$$(".mobile-menu a").forEach((l) => l.addEventListener("click", () => $("#mobileMenu")?.classList.remove("active")));

/* --------------------------
   KEYBOARD
-------------------------- */

document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return;
  closeCart(); closeAuth(); closeSearch(); $("#filters")?.classList.remove("mobile-open");
});

/* --------------------------
   INITIALIZE
-------------------------- */

document.addEventListener("DOMContentLoaded", async () => {
  renderAuth();
  renderCart();
  updateCartCount();
  await loadCategories();
  await loadProducts();
});
