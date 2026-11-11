/**
 * VoiceFlow — 3D Logo (procedural from reference image).
 *
 * Rebuilds the VoiceFlow app icon as a code-only procedural Three.js model:
 *   - Squircle frame with neon gradient border (cyan → purple)
 *   - Metallic "T" letter with beveled 3D edges
 *   - Speech bubble ring with microphone tail
 *   - White microphone icon + sound wave bars inside
 *   - Dark navy background with subtle flowing wave lines
 *   - Neon glow effects and depth layering
 *
 * Procedural approach: no textures downloaded at runtime.
 * All geometry, materials, and glow effects generated via code.
 */
import * as THREE from '../vendor/three.module.min.js';

// ─── Config ──────────────────────────────────────────────────────────────────
const LOGO = {
  colors: {
    cyan: new THREE.Color('#00D4FF'),
    blue: new THREE.Color('#0080FF'),
    purple: new THREE.Color('#8B5CF6'),
    magenta: new THREE.Color('#C026D3'),
    silver: new THREE.Color('#E2E8F0'),
    silverDark: new THREE.Color('#94A3B8'),
    white: new THREE.Color('#FFFFFF'),
    navy: new THREE.Color('#0A0E1A'),
    navyLight: new THREE.Color('#1E293B'),
    glowCyan: new THREE.Color('#00D4FF'),
    glowPurple: new THREE.Color('#8B5CF6'),
  },
  dims: {
    frameSize: 2.2,
    frameRadius: 0.45,
    frameThickness: 0.08,
    tWidth: 0.55,
    tHeight: 1.1,
    tDepth: 0.12,
    speechBubbleRadius: 0.42,
    micHeadRadius: 0.08,
    micHeadHeight: 0.18,
    micStandWidth: 0.03,
    micStandHeight: 0.12,
    micBaseWidth: 0.14,
    micBaseHeight: 0.02,
    waveBarCount: 5,
    waveBarMaxHeight: 0.12,
    waveBarWidth: 0.025,
    waveSpacing: 0.06,
  },
  anim: { rotSpeed: 0.15, parallaxStrength: 0.22 },
};

// ─── Shape helpers ───────────────────────────────────────────────────────────
function makeSquircleShape(size, radius) {
  const shape = new THREE.Shape();
  const hw = size / 2, hr = size / 2;
  const r = Math.min(radius, size / 2);
  shape.moveTo(-hw + r, -hr);
  shape.lineTo(hw - r, -hr);
  shape.absarc(hw - r, -hr + r, r, -Math.PI / 2, 0, false);
  shape.lineTo(hw, hr - r);
  shape.absarc(hw - r, hr - r, r, 0, Math.PI / 2, false);
  shape.lineTo(-hw + r, hr);
  shape.absarc(-hw + r, hr - r, r, Math.PI / 2, Math.PI, false);
  shape.lineTo(-hw, -hr + r);
  shape.absarc(-hw + r, -hr + r, r, Math.PI, Math.PI * 1.5, false);
  shape.closePath();
  return shape;
}

function makeSpeechBubbleShape(radius, tailSize) {
  const shape = new THREE.Shape();
  // Main circle
  shape.absarc(0, 0, radius, 0, Math.PI * 2, false);
  // Cut out tail triangle
  const hole = new THREE.Path();
  const tx = -radius * 0.6, ty = -radius * 0.7;
  hole.moveTo(tx - tailSize, ty - tailSize * 0.6);
  hole.lineTo(tx, ty + tailSize * 0.4);
  hole.lineTo(tx + tailSize, ty - tailSize * 0.6);
  hole.lineTo(tx - tailSize, ty - tailSize * 0.6);
  shape.holes.push(hole);
  return shape;
}

// ─── Canvas texture generators ───────────────────────────────────────────────
function makeGradientCanvas(width, height, stops, orientation = 'horizontal') {
  return new Promise((resolve) => {
    const c = document.createElement('canvas');
    c.width = width; c.height = height;
    const ctx = c.getContext('2d');
    const grad = orientation === 'horizontal'
      ? ctx.createLinearGradient(0, 0, width, 0)
      : ctx.createLinearGradient(0, 0, 0, height);
    stops.forEach(([pos, color]) => grad.addColorStop(pos, color));
    ctx.fillStyle = grad;
    ctx.fillRect(0, 0, width, height);
    const tex = new THREE.CanvasTexture(c);
    tex.colorSpace = THREE.SRGBColorSpace;
    resolve(tex);
  });
}

function makeNoiseCanvas(size, seed, colorFn) {
  const c = document.createElement('canvas');
  c.width = size; c.height = size;
  const ctx = c.getContext('2d');
  const idata = ctx.createImageData(size, size);
  const d = idata.data;
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const nx = x / size, ny = y / size;
      const v = (Math.sin(nx * 127.1 + ny * 311.7 + seed) * 43758.5453) % 1;
      const [r, g, b] = colorFn(Math.abs(v), nx, ny);
      const idx = (y * size + x) * 4;
      d[idx] = r; d[idx+1] = g; d[idx+2] = b; d[idx+3] = 255;
    }
  }
  ctx.putImageData(idata, 0, 0);
  const tex = new THREE.CanvasTexture(c);
  tex.colorSpace = THREE.SRGBColorSpace;
  return tex;
}

// ─── Geometry builders ───────────────────────────────────────────────────────
async function buildFrame() {
  const shape = makeSquircleShape(LOGO.dims.frameSize, LOGO.dims.frameRadius);
  const extrudeSettings = {
    depth: LOGO.dims.frameThickness,
    bevelEnabled: true,
    bevelThickness: 0.02,
    bevelSize: 0.02,
    bevelOffset: 0,
    bevelSegments: 3,
  };
  const geo = new THREE.ExtrudeGeometry(shape, extrudeSettings);
  geo.center();

  // Gradient texture for the neon frame
  const gradTex = await makeGradientCanvas(512, 64, [
    [0, '#00D4FF'],
    [0.3, '#0080FF'],
    [0.6, '#8B5CF6'],
    [1, '#C026D3'],
  ], 'horizontal');

  return new THREE.Mesh(geo, new THREE.MeshPhysicalMaterial({
    map: gradTex,
    metalness: 0.3,
    roughness: 0.25,
    clearcoat: 0.9,
    clearcoatRoughness: 0.1,
    emissive: LOGO.colors.cyan,
    emissiveIntensity: 0.15,
    emissiveMap: gradTex,
  }));
}

function buildBackground() {
  const geo = new THREE.PlaneGeometry(3.5, 3.5);
  const bgTex = makeNoiseCanvas(256, 7, (v) => {
    const dark = 0.04 + v * 0.06;
    return [dark * 255, dark * 255, (dark + 0.03) * 255];
  });

  return new THREE.Mesh(geo, new THREE.MeshPhysicalMaterial({
    color: LOGO.colors.navy,
    map: bgTex,
    metalness: 0.0,
    roughness: 0.9,
    side: THREE.DoubleSide,
  }));
}

function buildWaveLines() {
  const group = new THREE.Group();
  const lineCount = 8;
  for (let i = 0; i < lineCount; i++) {
    const points = [];
    const y = -1.2 + i * 0.35;
    const z = -0.3 + Math.random() * 0.1;
    for (let x = -1.5; x <= 1.5; x += 0.05) {
      const wave = Math.sin(x * 2 + i * 0.5) * 0.08 + Math.sin(x * 3.5 + i) * 0.04;
      points.push(new THREE.Vector3(x, y + wave, z));
    }
    const curve = new THREE.CatmullRomCurve3(points);
    const geo = new THREE.TubeGeometry(curve, 64, 0.008, 4, false);
    const opacity = 0.15 + Math.random() * 0.15;
    const mat = new THREE.MeshBasicMaterial({
      color: i % 2 === 0 ? LOGO.colors.cyan : LOGO.colors.purple,
      transparent: true,
      opacity,
    });
    group.add(new THREE.Mesh(geo, mat));
  }
  return group;
}

function buildTLetter() {
  const group = new THREE.Group();

  // Top bar
  const barGeo = new THREE.BoxGeometry(LOGO.dims.tWidth, LOGO.dims.tHeight * 0.3, LOGO.dims.tDepth, 4, 4, 2);
  // Bevel the edges by using a rounded box approach
  const barPos = barGeo.attributes.position;
  const roundEdges = (amt) => {
    for (let i = 0; i < barPos.count; i++) {
      let x = barPos.getX(i), y = barPos.getY(i), z = barPos.getZ(i);
      const hx = LOGO.dims.tWidth / 2, hy = LOGO.dims.tHeight * 0.15;
      // Snap corners to rounded edges
      const dx = Math.max(0, Math.abs(x) - (hx - amt));
      const dy = Math.max(0, Math.abs(y) - (hy - amt));
      const len = Math.sqrt(dx*dx + dy*dy);
      if (len > amt) {
        const scale = amt / len;
        x = x > 0 ? hx - amt + dx * scale : -(hx - amt + dx * scale);
        y = y > 0 ? hy - amt + dy * scale : -(hy - amt + dy * scale);
      }
      barPos.setXYZ(i, x, y, z);
    }
    barGeo.computeVertexNormals();
  };
  roundEdges(0.04);

  const barMat = new THREE.MeshPhysicalMaterial({
    color: LOGO.colors.silver,
    metalness: 0.95,
    roughness: 0.12,
    clearcoat: 1.0,
    clearcoatRoughness: 0.05,
    envMapIntensity: 1.5,
  });
  const bar = new THREE.Mesh(barGeo, barMat);
  bar.position.y = LOGO.dims.tHeight * 0.3;
  group.add(bar);

  // Stem
  const stemGeo = new THREE.BoxGeometry(LOGO.dims.tWidth * 0.4, LOGO.dims.tHeight * 0.65, LOGO.dims.tDepth, 4, 4, 2);
  const stemPos = stemGeo.attributes.position;
  const samt = 0.03;
  for (let i = 0; i < stemPos.count; i++) {
    let x = stemPos.getX(i), y = stemPos.getY(i), z = stemPos.getZ(i);
    const hx = LOGO.dims.tWidth * 0.2, hy = LOGO.dims.tHeight * 0.325;
    const dx = Math.max(0, Math.abs(x) - (hx - samt));
    const dy = Math.max(0, Math.abs(y) - (hy - samt));
    const len = Math.sqrt(dx*dx + dy*dy);
    if (len > samt) {
      const scale = samt / len;
      x = x > 0 ? hx - samt + dx * scale : -(hx - samt + dx * scale);
      y = y > 0 ? hy - samt + dy * scale : -(hy - samt + dy * scale);
    }
    stemPos.setXYZ(i, x, y, z);
  }
  stemGeo.computeVertexNormals();

  const stem = new THREE.Mesh(stemGeo, barMat.clone());
  stem.position.y = -LOGO.dims.tHeight * 0.1;
  group.add(stem);

  // Add edge highlights (thin strips on top edges)
  const highlightGeo = new THREE.BoxGeometry(LOGO.dims.tWidth + 0.01, 0.015, LOGO.dims.tDepth + 0.01);
  const highlightMat = new THREE.MeshPhysicalMaterial({
    color: LOGO.colors.white,
    emissive: LOGO.colors.white,
    emissiveIntensity: 0.3,
    metalness: 1.0,
    roughness: 0.1,
  });
  const highlight = new THREE.Mesh(highlightGeo, highlightMat);
  highlight.position.y = LOGO.dims.tHeight * 0.44;
  group.add(highlight);

  return group;
}

function buildSpeechBubble() {
  const group = new THREE.Group();

  // Outer ring (torus-like but custom shape)
  const outerGeo = new THREE.TorusGeometry(LOGO.dims.speechBubbleRadius, 0.045, 16, 64);
  const outerMat = new THREE.MeshPhysicalMaterial({
    color: LOGO.colors.cyan,
    emissive: LOGO.colors.cyan,
    emissiveIntensity: 0.4,
    metalness: 0.2,
    roughness: 0.3,
    clearcoat: 0.8,
  });
  const outer = new THREE.Mesh(outerGeo, outerMat);
  group.add(outer);

  // Gradient ring effect
  const ringGradGeo = new THREE.RingGeometry(LOGO.dims.speechBubbleRadius - 0.02, LOGO.dims.speechBubbleRadius + 0.06, 64);
  const ringGradTex = makeNoiseCanvas(256, 10, (v) => {
    const r = 0.1 + v * 0.2;
    const g = 0.1 + v * 0.15;
    const b = 0.3 + v * 0.3;
    return [r * 255, g * 255, b * 255];
  });
  const ringMat = new THREE.MeshBasicMaterial({
    map: ringGradTex,
    transparent: true,
    opacity: 0.5,
    side: THREE.DoubleSide,
  });
  const ringGrad = new THREE.Mesh(ringGradGeo, ringMat);
  group.add(ringGrad);

  return group;
}

function buildMicrophone() {
  const group = new THREE.Group();

  // Mic head (pill/capsule shape)
  const headGeo = new THREE.CapsuleGeometry(LOGO.dims.micHeadRadius, LOGO.dims.micHeadHeight, 8, 16);
  const headMat = new THREE.MeshPhysicalMaterial({
    color: LOGO.colors.white,
    metalness: 0.1,
    roughness: 0.4,
    clearcoat: 0.6,
  });
  const head = new THREE.Mesh(headGeo, headMat);
  head.position.y = 0.06;
  group.add(head);

  // Mic stand (U-shaped support)
  const standGeo = new THREE.TorusGeometry(0.04, 0.012, 8, 16, Math.PI);
  const standMat = new THREE.MeshPhysicalMaterial({
    color: LOGO.colors.silver,
    metalness: 0.9,
    roughness: 0.2,
  });
  const stand = new THREE.Mesh(standGeo, standMat);
  stand.position.y = -0.04;
  group.add(stand);

  // Mic base
  const baseGeo = new THREE.BoxGeometry(LOGO.dims.micBaseWidth, LOGO.dims.micBaseHeight, 0.04);
  const baseMat = new THREE.MeshPhysicalMaterial({
    color: LOGO.colors.silver,
    metalness: 0.9,
    roughness: 0.2,
  });
  const base = new THREE.Mesh(baseGeo, baseMat);
  base.position.y = -0.12;
  group.add(base);

  return group;
}

function buildSoundWaves() {
  const group = new THREE.Group();
  const { waveBarCount, waveBarMaxHeight, waveBarWidth, waveSpacing } = LOGO.dims;

  for (let i = 0; i < waveBarCount; i++) {
    // Left side
    const hL = (Math.sin(i * 1.3 + 0.5) * 0.5 + 0.5) * waveBarMaxHeight;
    const barGeoL = new THREE.BoxGeometry(waveBarWidth, hL, 0.03);
    const barMat = new THREE.MeshPhysicalMaterial({
      color: LOGO.colors.white,
      emissive: LOGO.colors.cyan,
      emissiveIntensity: 0.3,
      metalness: 0.3,
      roughness: 0.5,
    });
    const barL = new THREE.Mesh(barGeoL, barMat);
    barL.position.x = -0.22 - i * waveSpacing;
    barL.position.y = 0;
    group.add(barL);

    // Right side
    const hR = (Math.sin(i * 1.7 + 1.2) * 0.5 + 0.5) * waveBarMaxHeight;
    const barGeoR = new THREE.BoxGeometry(waveBarWidth, hR, 0.03);
    const barR = new THREE.Mesh(barGeoR, barMat.clone());
    barR.position.x = 0.22 + i * waveSpacing;
    barR.position.y = 0;
    group.add(barR);
  }

  return group;
}

function buildGlowEffects() {
  const group = new THREE.Group();

  // Soft glow behind the frame
  const glowGeo = new THREE.PlaneGeometry(3.2, 3.2);
  const glowTex = makeNoiseCanvas(256, 20, (v) => {
    const intensity = 0.08 + v * 0.06;
    return [intensity * 100, intensity * 150, intensity * 255];
  });
  const glowMat = new THREE.MeshBasicMaterial({
    map: glowTex,
    transparent: true,
    opacity: 0.4,
    blending: THREE.AdditiveBlending,
    depthWrite: false,
    side: THREE.DoubleSide,
  });
  const glow = new THREE.Mesh(glowGeo, glowMat);
  glow.position.z = -0.2;
  group.add(glow);

  // Point lights for neon glow
  const light1 = new THREE.PointLight(LOGO.colors.cyan, 2, 4);
  light1.position.set(-1, 0.5, 1);
  group.add(light1);

  const light2 = new THREE.PointLight(LOGO.colors.purple, 2, 4);
  light2.position.set(1, -0.5, 1);
  group.add(light2);

  return group;
}

// Landing stage only. Rings lie on the ground (XZ). CircleGeometry faces +z;
// rotation.x = -π/2 turns that normal to +y so the disc is seen from above.
function buildVoiceField() {
  const group = new THREE.Group();
  const rings = [];
  for (let i = 0; i < 3; i++) {
    const mesh = new THREE.Mesh(
      new THREE.TorusGeometry(1.2, 0.007, 8, 80),
      new THREE.MeshBasicMaterial({
        color: i === 1 ? LOGO.colors.purple : LOGO.colors.cyan,
        transparent: true,
        opacity: 0.22,
        depthWrite: false,
      })
    );
    mesh.rotation.x = Math.PI / 2;
    mesh.position.y = -1.02;
    mesh.userData.phase = i / 3;
    group.add(mesh);
    rings.push(mesh);
  }

  const disc = new THREE.Mesh(
    new THREE.CircleGeometry(1.45, 48),
    new THREE.MeshBasicMaterial({
      color: 0x3b82f6,
      transparent: true,
      opacity: 0.14,
      depthWrite: false,
      side: THREE.DoubleSide,
    })
  );
  disc.rotation.x = -Math.PI / 2;
  disc.position.y = -1.06;
  group.add(disc);

  group.userData.rings = rings;
  return group;
}

// ─── Scene assembly ──────────────────────────────────────────────────────────
async function createScene(container, options = {}) {
  const {
    isClone = false,
    reduceMotion = false,
    isMobile = /Mobi|Android|iPhone|iPad/i.test(navigator.userAgent),
    isLowEnd = navigator.hardwareConcurrency && navigator.hardwareConcurrency <= 4,
    variant = 'showcase'
  } = options;
  const isHero = variant === 'hero';

  const renderer = new THREE.WebGLRenderer({ 
    antialias: !isMobile, // Disable AA on mobile for performance
    alpha: true, 
    powerPreference: isMobile ? 'low-power' : 'high-performance',
    preserveDrawingBuffer: false
  });
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, isMobile ? 1.5 : 2));
  renderer.setClearColor(0x000000, 0);
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  renderer.toneMapping = THREE.ACESFilmicToneMapping;
  renderer.toneMappingExposure = 1.0;
  container.appendChild(renderer.domElement);

  // Store renderer reference on canvas for external resize handling
  renderer.domElement._threeRenderer = renderer;

  const scene = new THREE.Scene();
  const camera = new THREE.PerspectiveCamera(isHero ? 30 : 40, 1, 0.1, 100);
  // Hero camera sits on +z, slightly above the mark, looking toward −z.
  // Screen +x is world +x from this pose.
  const camBase = isHero ? new THREE.Vector3(0.2, 0.42, 6.6) : new THREE.Vector3(0, 0, 4.5);
  camera.position.copy(camBase);

  // Ambient
  scene.add(new THREE.AmbientLight(0xffffff, 0.4));
  const key = new THREE.DirectionalLight(0xfff4e6, 1.8); key.position.set(3, 4, 5); scene.add(key);
  const fill = new THREE.DirectionalLight(0x8899ff, 0.5); fill.position.set(-4, 2, 3); scene.add(fill);
  const rim = new THREE.DirectionalLight(0x22d3ee, 0.6); rim.position.set(0, -3, -4); scene.add(rim);

  const logo = new THREE.Group();

  // Build all components. The landing stage floats the mark; the
  // showcase keeps the icon card (navy plate, wave lines, glow).
  logo.add(await buildFrame());
  if (!isHero) {
    logo.add(buildBackground());
    logo.children[1].position.z = -0.15;
    logo.add(buildWaveLines());
    logo.add(buildGlowEffects());
  }

  // T letter
  const tGroup = buildTLetter();
  tGroup.position.set(-0.55, 0, 0.15);
  logo.add(tGroup);

  // Speech bubble
  const bubbleGroup = buildSpeechBubble();
  bubbleGroup.position.set(0.5, 0, 0.1);
  logo.add(bubbleGroup);

  // Microphone inside bubble
  const micGroup = buildMicrophone();
  micGroup.position.set(0.5, 0, 0.2);
  logo.add(micGroup);

  // Sound waves
  const wavesGroup = buildSoundWaves();
  wavesGroup.position.set(0.5, 0, 0.22);
  logo.add(wavesGroup);

  scene.add(logo);

  let voiceField = null;
  if (isHero) {
    // No environment map, so a near-mirror metal reads as black. Soften it
    // so the letter catches the key light as brushed silver.
    logo.traverse((obj) => {
      const mat = obj.material;
      if (!mat || mat.metalness == null || mat.metalness < 0.7) return;
      mat.metalness = 0.42;
      mat.roughness = Math.max(mat.roughness, 0.32);
      mat.color = new THREE.Color('#E7EDF6');
      mat.envMapIntensity = 0.4;
    });
    logo.scale.setScalar(0.78);
    const front = new THREE.DirectionalLight(0xf8fbff, 1.8);
    front.position.set(0.4, 1.4, 5);
    scene.add(front);
    scene.add(new THREE.HemisphereLight(0xdbeafe, 0x10182c, 0.7));
    voiceField = buildVoiceField();
    scene.add(voiceField);
  }

  let mx = 0, my = 0;
  if (!reduceMotion && !isMobile) {
    document.addEventListener('mousemove', (e) => {
      mx = (e.clientX / window.innerWidth - 0.5) * 2;
      my = (e.clientY / window.innerHeight - 0.5) * 2;
    }, { passive: true });
  }

  let time = 0;
  const startTime = performance.now();
  let rafId = null;
  let lastFrameTime = 0;
  const frameThrottle = (isMobile || isLowEnd) ? 33 : 16; // ~30fps on mobile/low-end

  function resize() {
    const rect = container.getBoundingClientRect();
    const w = Math.max(1, rect.width);
    const h = Math.max(1, rect.height);
    if (isHero) {
      renderer.setSize(w, h, false);
      camera.aspect = w / h;
    } else {
      const size = Math.min(w, h) || 400;
      renderer.setSize(size, size);
      camera.aspect = 1;
    }
    camera.updateProjectionMatrix();
  }
  resize();
  const ro = new ResizeObserver(resize);
  ro.observe(container);

  function tick(now) {
    rafId = requestAnimationFrame(tick);
    
    // Throttle frame rate on mobile/low-end
    if (now - lastFrameTime < frameThrottle) return;
    lastFrameTime = now;

    time = (now - startTime) * 0.001;
    
    if (!reduceMotion) {
      if (isHero) {
        logo.position.y = Math.sin(time * 0.7) * 0.045;
        logo.rotation.y = Math.sin(time * 0.28) * 0.18;
        logo.rotation.x = Math.sin(time * 0.2) * 0.035;
        const rings = voiceField.userData.rings;
        for (let i = 0; i < rings.length; i++) {
          const p = (time * 0.16 + rings[i].userData.phase) % 1;
          const s = 0.82 + p * 0.85;
          rings[i].scale.setScalar(s);
          rings[i].material.opacity = (1 - p) * 0.4;
        }
      } else {
        logo.rotation.y = Math.sin(time * LOGO.anim.rotSpeed) * 0.4;
        logo.rotation.x = Math.cos(time * LOGO.anim.rotSpeed * 0.7) * 0.08;
      }
    }
    
    if (!reduceMotion && !isMobile) {
      const sway = isHero ? 0.18 : LOGO.anim.parallaxStrength;
      const targetX = camBase.x + mx * sway;
      const targetY = camBase.y - my * sway * 0.65;
      camera.position.x += (targetX - camera.position.x) * 0.045;
      camera.position.y += (targetY - camera.position.y) * 0.045;
    }
    
    camera.lookAt(0, 0, 0);
    renderer.render(scene, camera);
  }
  
  // Handle reduced motion
  if (reduceMotion) {
    logo.rotation.y = 0;
    logo.rotation.x = 0;
    camera.lookAt(0, 0, 0);
    renderer.render(scene, camera);
  } else {
    rafId = requestAnimationFrame(tick);
  }

  // Cleanup function
  function dispose() {
    if (rafId) cancelAnimationFrame(rafId);
    ro.disconnect();
    renderer.dispose();
    // Dispose geometries and materials
    scene.traverse(obj => {
      if (obj.geometry) obj.geometry.dispose();
      if (obj.material) {
        if (Array.isArray(obj.material)) {
          obj.material.forEach(m => m.dispose());
        } else {
          obj.material.dispose();
        }
      }
    });
    if (container.contains(renderer.domElement)) {
      container.removeChild(renderer.domElement);
    }
  }

  return { renderer, scene, camera, logo, dispose, resize };
}

// ─── Primary instance ────────────────────────────────────────────────────────
let primaryInstance = null;
let primaryContainer = null;

async function init() {
  const container = document.getElementById('logo-container');
  if (!container) throw new Error('VoiceFlow 3D logo: #logo-container not found');
  
  primaryContainer = container;
  
  const reduceMotion = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
  const isMobile = /Mobi|Android|iPhone|iPad/i.test(navigator.userAgent);
  const isLowEnd = navigator.hardwareConcurrency && navigator.hardwareConcurrency <= 4;

  primaryInstance = await createScene(container, {
    reduceMotion, isMobile, isLowEnd, variant: 'hero'
  });
  
  // Handle reduced motion changes
  if (window.matchMedia) {
    const mediaQuery = window.matchMedia('(prefers-reduced-motion: reduce)');
    mediaQuery.addEventListener('change', (e) => {
      if (primaryInstance) {
        primaryInstance.dispose();
        init();
      }
    });
  }
}

// ─── Clone support for multiple containers ──────────────────────────────────
window.VoiceFlowLogo = {
  cloneTo: async function(targetContainer) {
    const reduceMotion = !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
    const isMobile = /Mobi|Android|iPhone|iPad/i.test(navigator.userAgent);
    const isLowEnd = navigator.hardwareConcurrency && navigator.hardwareConcurrency <= 4;
    
    return await createScene(targetContainer, { 
      isClone: true, 
      reduceMotion, 
      isMobile, 
      isLowEnd 
    });
  },
  
  // Expose method to trigger resize on all instances
  resizeAll: function() {
    if (primaryInstance) primaryInstance.resize();
  }
};

// Init the primary logo instance
init().catch(console.error);