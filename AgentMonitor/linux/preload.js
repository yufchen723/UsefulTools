const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('monitor', {
  menu: () => ipcRenderer.send('orb:menu'),
  doubleClick: () => ipcRenderer.send('orb:double'),
  resize: (f) => ipcRenderer.send('orb:resize', f),
  card: (id, action) => ipcRenderer.send('orb:card', { id, action }),
  dragStart: (ox, oy) => ipcRenderer.send('orb:drag-start', { ox, oy }),
  dragEnd: () => ipcRenderer.send('orb:drag-end'),
});
