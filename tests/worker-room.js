import app from 'app.wasm';
import { makeHandler, objectClass } from './js/index.js';
// The Durable Object classes of examples/room.roc, before makeHandler (the manifest checks them at load).
export const Chat = objectClass('Chat');
export const Room = objectClass('Room');
export const Notes = objectClass('Notes');
export default makeHandler(app);
