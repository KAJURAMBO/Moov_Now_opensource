/* ==========================================================================
   🏃 MOOV NOW REVIVAL FRONTEND CONTROLLER
   Integrates Three.js 3D motion, Chart.js telemetry, WebSockets, & Workout Coach
   ========================================================================== */

document.addEventListener('DOMContentLoaded', () => {
  console.log('🏃 Moov Now Revival Controller Initializing...');

  // State Management
  const state = {
    websocket: null,
    isConnected: false,
    activeWorkout: false,
    activeWorkoutId: null,
    selectedActivity: 'Running',
    workoutTimerInterval: null,
    workoutDurationSec: 0,
    currentPitch: 0,
    currentRoll: 0,
    currentYaw: 0,
    telemetryHistory: {
      labels: [],
      accelX: [],
      accelY: [],
      accelZ: [],
      impact: []
    }
  };

  // UI Element References
  const elements = {
    statusBadge: document.getElementById('status-badge'),
    statusIndicator: document.getElementById('status-indicator'),
    statusText: document.getElementById('status-text'),
    btnOpenScan: document.getElementById('btn-open-scan'),
    valDailySteps: document.getElementById('val-daily-steps'),
    valActiveMin: document.getElementById('val-active-min'),
    valCalories: document.getElementById('val-calories'),
    valDistance: document.getElementById('val-distance'),
    barSteps: document.getElementById('bar-steps'),
    barActive: document.getElementById('bar-active'),
    barCalories: document.getElementById('bar-calories'),
    barDistance: document.getElementById('bar-distance'),
    valPitch: document.getElementById('val-pitch'),
    valRoll: document.getElementById('val-roll'),
    valYaw: document.getElementById('val-yaw'),
    badgeActivity: document.getElementById('badge-activity'),
    timerDisplay: document.getElementById('timer-display'),
    timerStatus: document.getElementById('timer-status'),
    workoutStepsVal: document.getElementById('workout-steps-val'),
    workoutCadenceVal: document.getElementById('workout-cadence-val'),
    workoutImpactVal: document.getElementById('workout-impact-val'),
    btnWorkoutToggle: document.getElementById('btn-workout-toggle'),
    workoutTableBody: document.getElementById('workout-table-body'),
    modalScanner: document.getElementById('modal-scanner'),
    btnCloseModal: document.getElementById('btn-close-modal'),
    btnScanTrigger: document.getElementById('btn-scan-trigger'),
    btnAutoLatch: document.getElementById('btn-auto-latch'),
    bleDeviceList: document.getElementById('ble-device-list')
  };

  // --------------------------------------------------------------------------
  // 1. THREE.JS 3D MOTION ORIENTATION VISUALIZER
  // --------------------------------------------------------------------------
  let scene, camera, renderer, moovPuck, moovStrap;

  function init3DMotionViewer() {
    const container = document.getElementById('canvas-3d-container');
    if (!container) return;

    const width = container.clientWidth;
    const height = container.clientHeight;

    scene = new THREE.Scene();
    scene.background = new THREE.Color(0x050810);

    camera = new THREE.PerspectiveCamera(45, width / height, 0.1, 1000);
    camera.position.set(0, 0, 8);

    renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true });
    renderer.setSize(width, height);
    renderer.setPixelRatio(window.devicePixelRatio);
    container.appendChild(renderer.domElement);

    // Lighting
    const ambientLight = new THREE.AmbientLight(0xffffff, 0.6);
    scene.add(ambientLight);

    const cyanLight = new THREE.PointLight(0x00F2FE, 2, 20);
    cyanLight.position.set(5, 5, 5);
    scene.add(cyanLight);

    const violetLight = new THREE.PointLight(0x7F00FF, 2, 20);
    violetLight.position.set(-5, -5, -5);
    scene.add(violetLight);

    // Create Moov Now Wristband/Puck Group
    const moovGroup = new THREE.Group();

    // Moov Puck Cylinder (Disk)
    const puckGeo = new THREE.CylinderGeometry(1.6, 1.6, 0.4, 32);
    const puckMat = new THREE.MeshPhongMaterial({
      color: 0x12182B,
      emissive: 0x00F2FE,
      emissiveIntensity: 0.15,
      shininess: 90
    });
    moovPuck = new THREE.Mesh(puckGeo, puckMat);
    moovPuck.rotation.x = Math.PI / 2;
    moovGroup.add(moovPuck);

    // Outer Ring Highlight
    const ringGeo = new THREE.TorusGeometry(1.65, 0.05, 16, 64);
    const ringMat = new THREE.MeshBasicMaterial({ color: 0x00F2FE });
    const ringMesh = new THREE.Mesh(ringGeo, ringMat);
    moovGroup.add(ringMesh);

    // Strap Band
    const strapGeo = new THREE.BoxGeometry(0.7, 5.0, 0.15);
    const strapMat = new THREE.MeshStandardMaterial({ color: 0x1A233D, roughness: 0.8 });
    moovStrap = new THREE.Mesh(strapGeo, strapMat);
    moovStrap.position.z = -0.2;
    moovGroup.add(moovStrap);

    scene.add(moovGroup);

    // Grid helper
    const grid = new THREE.GridHelper(15, 15, 0x00F2FE, 0x12182B);
    grid.position.y = -3;
    scene.add(grid);

    // Animation Loop
    function animate3D() {
      requestAnimationFrame(animate3D);

      // Smooth interpolation (lerp) towards target pitch/roll/yaw
      const targetRadX = (state.currentPitch * Math.PI) / 180;
      const targetRadY = (state.currentYaw * Math.PI) / 180;
      const targetRadZ = (state.currentRoll * Math.PI) / 180;

      moovGroup.rotation.x += (targetRadX - moovGroup.rotation.x) * 0.15;
      moovGroup.rotation.y += (targetRadY - moovGroup.rotation.y) * 0.15;
      moovGroup.rotation.z += (targetRadZ - moovGroup.rotation.z) * 0.15;

      renderer.render(scene, camera);
    }
    animate3D();

    // Handle Window Resize
    window.addEventListener('resize', () => {
      const w = container.clientWidth;
      const h = container.clientHeight;
      camera.aspect = w / h;
      camera.updateProjectionMatrix();
      renderer.setSize(w, h);
    });
  }

  // --------------------------------------------------------------------------
  // 2. CHART.JS REAL-TIME STREAMING TELEMETRY GRAPH
  // --------------------------------------------------------------------------
  let telemetryChart;

  function initTelemetryChart() {
    const ctx = document.getElementById('chart-telemetry')?.getContext('2d');
    if (!ctx) return;

    // Fill initial 40 blank samples
    const maxSamples = 40;
    const initialLabels = Array(maxSamples).fill('');
    const initialData = Array(maxSamples).fill(0);

    telemetryChart = new Chart(ctx, {
      type: 'line',
      data: {
        labels: initialLabels,
        datasets: [
          {
            label: 'Accel X (g)',
            borderColor: '#00F2FE',
            borderWidth: 2,
            pointRadius: 0,
            tension: 0.3,
            data: [...initialData]
          },
          {
            label: 'Accel Y (g)',
            borderColor: '#E100FF',
            borderWidth: 2,
            pointRadius: 0,
            tension: 0.3,
            data: [...initialData]
          },
          {
            label: 'Accel Z (g)',
            borderColor: '#00FF87',
            borderWidth: 2,
            pointRadius: 0,
            tension: 0.3,
            data: [...initialData]
          },
          {
            label: 'Impact Force (g)',
            borderColor: '#FF5E00',
            borderWidth: 2,
            borderDash: [4, 4],
            pointRadius: 0,
            tension: 0.1,
            data: [...initialData]
          }
        ]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        animation: false,
        plugins: {
          legend: {
            position: 'top',
            labels: { color: '#8E9BAE', font: { family: 'Outfit', size: 12 } }
          }
        },
        scales: {
          x: { display: false },
          y: {
            grid: { color: 'rgba(255, 255, 255, 0.06)' },
            ticks: { color: '#8E9BAE', font: { family: 'JetBrains Mono', size: 10 } },
            suggestedMin: -3.0,
            suggestedMax: 4.0
          }
        }
      }
    });
  }

  function updateTelemetryChart(accel, impactG) {
    if (!telemetryChart) return;

    const datasets = telemetryChart.data.datasets;
    datasets[0].data.push(accel.x);
    datasets[1].data.push(accel.y);
    datasets[2].data.push(accel.z);
    datasets[3].data.push(impactG);

    // Maintain sliding window buffer of 40 points
    if (datasets[0].data.length > 40) {
      datasets[0].data.shift();
      datasets[1].data.shift();
      datasets[2].data.shift();
      datasets[3].data.shift();
    }

    telemetryChart.update('none');
  }

  // --------------------------------------------------------------------------
  // 3. WEBSOCKET REAL-TIME DATA STREAM
  // --------------------------------------------------------------------------
  function connectWebSocket() {
    const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
    const wsUrl = `${protocol}//${window.location.host}/ws/live`;

    console.log(`Connecting WebSocket to ${wsUrl}...`);
    state.websocket = new WebSocket(wsUrl);

    state.websocket.onopen = () => {
      console.log('[✓] WebSocket Connected to Moov Engine');
    };

    state.websocket.onmessage = (event) => {
      try {
        const payload = JSON.parse(event.data);
        handleTelemetryUpdate(payload);
      } catch (err) {
        console.error('WebSocket payload decode error:', err);
      }
    };

    state.websocket.onclose = () => {
      console.warn('WebSocket disconnected. Retrying in 3 seconds...');
      setTimeout(connectWebSocket, 3000);
    };

    state.websocket.onerror = (err) => {
      console.error('WebSocket Error:', err);
    };
  }

  function handleTelemetryUpdate(data) {
    const { device, motion, workout } = data;

    // Device & Header Status
    state.isConnected = device.connected;

    if (device.connected) {
      elements.statusIndicator.className = 'status-indicator';
      elements.statusText.textContent = `Moov Connected (${device.name})`;
    } else {
      elements.statusIndicator.className = 'status-indicator disconnected';
      elements.statusText.textContent = 'Disconnected';
    }

    // Motion Telemetry
    if (motion) {
      const { accel, orientation, impact_g, cadence_rpm, activity } = motion;

      state.currentPitch = orientation.pitch;
      state.currentRoll = orientation.roll;
      state.currentYaw = orientation.yaw;

      elements.valPitch.textContent = `${orientation.pitch.toFixed(1)}°`;
      elements.valRoll.textContent = `${orientation.roll.toFixed(1)}°`;
      elements.valYaw.textContent = `${orientation.yaw.toFixed(1)}°`;

      elements.badgeActivity.textContent = activity || 'Idle';

      elements.workoutCadenceVal.textContent = cadence_rpm || 0;
      elements.workoutImpactVal.textContent = `${impact_g.toFixed(1)}g`;

      // Update Real-Time Chart
      updateTelemetryChart(accel, impact_g);
    }

    // Workout Metrics
    if (workout) {
      if (workout.active) {
        state.activeWorkout = true;
        state.activeWorkoutId = workout.workout_id;
        elements.workoutStepsVal.textContent = workout.steps;
        if (!state.workoutTimerInterval) {
          startTimerLocal(workout.duration_sec);
        }
      }
    }
  }

  // --------------------------------------------------------------------------
  // 4. WORKOUT RECORDER & TIMER CONTROLLER
  // --------------------------------------------------------------------------
  // Activity Selection Buttons
  document.querySelectorAll('.act-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('.act-btn').forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      state.selectedActivity = btn.dataset.activity;
    });
  });

  elements.btnWorkoutToggle.addEventListener('click', async () => {
    if (!state.activeWorkout) {
      // Start Workout
      try {
        const res = await fetch('/api/workouts/start', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ activity_type: state.selectedActivity })
        });
        const data = await res.json();
        if (data.success) {
          state.activeWorkout = true;
          state.activeWorkoutId = data.workout_id;
          elements.btnWorkoutToggle.textContent = '⏹️ Stop Workout Session';
          elements.btnWorkoutToggle.className = 'btn btn-danger';
          elements.timerStatus.textContent = `Recording ${state.selectedActivity} session...`;
          startTimerLocal(0);
        }
      } catch (err) {
        alert('Failed to start workout session');
      }
    } else {
      // Stop Workout
      try {
        const res = await fetch('/api/workouts/stop', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ workout_id: state.activeWorkoutId })
        });
        const data = await res.json();
        if (data.success) {
          state.activeWorkout = false;
          state.activeWorkoutId = null;
          stopTimerLocal();
          elements.btnWorkoutToggle.textContent = '▶️ Start Workout Session';
          elements.btnWorkoutToggle.className = 'btn btn-accent';
          elements.timerStatus.textContent = 'Workout saved! Ready for next session.';
          fetchWorkoutsHistory();
          fetchDailyStats();
        }
      } catch (err) {
        alert('Failed to stop workout session');
      }
    }
  });

  function startTimerLocal(initialSec = 0) {
    stopTimerLocal();
    state.workoutDurationSec = initialSec;
    state.workoutTimerInterval = setInterval(() => {
      state.workoutDurationSec++;
      const hrs = String(Math.floor(state.workoutDurationSec / 3600)).padStart(2, '0');
      const mins = String(Math.floor((state.workoutDurationSec % 3600) / 60)).padStart(2, '0');
      const secs = String(state.workoutDurationSec % 60).padStart(2, '0');
      elements.timerDisplay.textContent = `${hrs}:${mins}:${secs}`;
    }, 1000);
  }

  function stopTimerLocal() {
    if (state.workoutTimerInterval) {
      clearInterval(state.workoutTimerInterval);
      state.workoutTimerInterval = null;
    }
  }

  // --------------------------------------------------------------------------
  // 5. HISTORY & STATS SYNC
  // --------------------------------------------------------------------------
  async function fetchDailyStats() {
    try {
      const res = await fetch('/api/daily_stats');
      const data = await res.json();
      elements.valDailySteps.textContent = data.total_steps.toLocaleString();
      elements.valActiveMin.textContent = `${data.active_minutes} min`;
      elements.valCalories.textContent = `${data.calories_burned.toFixed(1)} kcal`;
      elements.valDistance.textContent = `${data.distance_km.toFixed(2)} km`;

      elements.barSteps.style.width = `${Math.min(100, (data.total_steps / 10000) * 100)}%`;
      elements.barActive.style.width = `${Math.min(100, (data.active_minutes / 60) * 100)}%`;
    } catch (err) {
      console.error('Failed to fetch daily stats:', err);
    }
  }

  async function fetchWorkoutsHistory() {
    try {
      const res = await fetch('/api/workouts');
      const data = await res.json();
      renderWorkoutTable(data.workouts);
    } catch (err) {
      console.error('Failed to fetch workouts history:', err);
    }
  }

  function renderWorkoutTable(workouts) {
    if (!elements.workoutTableBody) return;
    elements.workoutTableBody.innerHTML = '';

    workouts.forEach(w => {
      const tr = document.createElement('tr');
      
      const badgeClass = `badge-${(w.activity_type || 'walking').toLowerCase()}`;
      const dt = new Date(w.start_time * 1000).toLocaleString('en-US', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });

      const durationMin = Math.floor(w.duration_sec / 60);
      const durationSec = w.duration_sec % 60;
      const durationStr = `${durationMin}m ${durationSec}s`;

      tr.innerHTML = `
        <td><span class="badge-activity ${badgeClass}">${w.activity_type}</span></td>
        <td style="color: var(--text-secondary); font-size: 0.8rem;">${dt}</td>
        <td style="font-family: var(--font-mono);">${durationStr}</td>
        <td style="font-family: var(--font-mono);">${w.total_steps ? w.total_steps.toLocaleString() : '-'}</td>
        <td style="font-family: var(--font-mono);">${w.avg_cadence_rpm || '-'} RPM</td>
        <td style="font-family: var(--font-mono); color: var(--accent-amber);">${w.max_impact_g ? w.max_impact_g.toFixed(1) + 'g' : '-'}</td>
        <td style="font-family: var(--font-mono); color: var(--accent-cyan);">${w.calories_burned ? w.calories_burned.toFixed(1) : '0'} kcal</td>
      `;
      elements.workoutTableBody.appendChild(tr);
    });
  }

  // --------------------------------------------------------------------------
  // 6. BLE DEVICE SCANNER MODAL CONTROLLER
  // --------------------------------------------------------------------------
  elements.btnOpenScan.addEventListener('click', () => {
    elements.modalScanner.classList.add('active');
  });

  elements.btnCloseModal.addEventListener('click', () => {
    elements.modalScanner.classList.remove('active');
  });

  elements.btnAutoLatch.addEventListener('click', async () => {
    elements.bleDeviceList.innerHTML = `
      <div style="text-align: center; padding: 2rem;">
        <div style="font-size: 2rem; margin-bottom: 0.5rem; animation: pulse 1s infinite alternate;">⚡</div>
        <div style="color: #00f2fe; font-weight: 700; font-size: 1.1rem;">AUTO-LATCH ACTIVE</div>
        <div style="color: #fff; font-weight: 600; margin-top: 0.5rem;">PRESS YOUR MOOV BUTTON NOW!</div>
        <div style="font-size: 0.75rem; color: var(--text-muted); margin-top: 0.25rem;">Waiting for red LED light to flash...</div>
      </div>
    `;

    try {
      const res = await fetch('/api/auto_latch', { method: 'POST' });
      const data = await res.json();
      if (data.success) {
        elements.bleDeviceList.innerHTML = `<div style="color: var(--accent-green); font-weight: 700; text-align: center; padding: 1.5rem;">🎉 ${data.message}</div>`;
        setTimeout(() => elements.modalScanner.classList.remove('active'), 1500);
      } else {
        elements.bleDeviceList.innerHTML = `<div style="color: var(--accent-red); text-align: center; padding: 1.5rem;">⚠️ ${data.message}</div>`;
      }
    } catch (err) {
      elements.bleDeviceList.innerHTML = `<div style="color: var(--accent-red); text-align: center;">Error: ${err.message}</div>`;
    }
  });

  elements.btnScanTrigger.addEventListener('click', async () => {
    elements.bleDeviceList.innerHTML = `
      <div style="text-align: center; padding: 2rem;">
        <div style="font-size: 1.5rem; margin-bottom: 0.5rem;">📡</div>
        <div style="color: var(--accent-cyan); font-weight: 600;">Scanning for BLE devices...</div>
        <div style="font-size: 0.75rem; color: var(--text-muted);">Ensure Moov device is woke up into pairing mode</div>
      </div>
    `;

    try {
      const res = await fetch('/api/scan', { method: 'POST' });
      const data = await res.json();
      renderBLEDeviceList(data.devices);
    } catch (err) {
      elements.bleDeviceList.innerHTML = `<div style="color: var(--accent-red); text-align: center;">Scan Error: ${err.message}</div>`;
    }
  });

  function renderBLEDeviceList(devices) {
    if (!devices || devices.length === 0) {
      elements.bleDeviceList.innerHTML = `
        <div style="text-align: center; padding: 1.5rem; color: var(--text-secondary);">
          No BLE devices discovered nearby.<br>
          <span style="font-size: 0.75rem;">Make sure Bluetooth is turned ON in Windows and device is shaken to wake up.</span>
        </div>
      `;
      return;
    }

    elements.bleDeviceList.innerHTML = '';
    devices.forEach(dev => {
      const div = document.createElement('div');
      div.className = 'device-item';
      const isMoov = dev.is_moov || dev.name.toLowerCase().includes('moov');

      div.innerHTML = `
        <div>
          <div class="device-info-name">
            ${isMoov ? '🔥 ' : ''}${dev.name}
          </div>
          <div class="device-info-mac">${dev.address}</div>
        </div>
        <div style="display: flex; align-items: center; gap: 1rem;">
          <span style="font-size: 0.8rem; font-family: var(--font-mono); color: var(--text-secondary);">${dev.rssi} dBm</span>
          <button class="btn btn-primary" style="padding: 0.4rem 0.8rem; font-size: 0.8rem;">Connect</button>
        </div>
      `;

      div.querySelector('button').addEventListener('click', () => connectToBLEDevice(dev.address));
      elements.bleDeviceList.appendChild(div);
    });
  }

  async function connectToBLEDevice(macAddress) {
    try {
      const res = await fetch('/api/connect', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ address: macAddress })
      });
      const data = await res.json();
      alert(data.message);
      if (data.success) {
        elements.modalScanner.classList.remove('active');
      }
    } catch (err) {
      alert(`Connect error: ${err.message}`);
    }
  }

  // --------------------------------------------------------------------------
  // INITIALIZATION CALLS
  // --------------------------------------------------------------------------
  init3DMotionViewer();
  initTelemetryChart();
  connectWebSocket();
  fetchDailyStats();
  fetchWorkoutsHistory();
  // Refresh daily stats live (steps/calories/distance/active minutes) every 3s
  setInterval(fetchDailyStats, 3000);
});
