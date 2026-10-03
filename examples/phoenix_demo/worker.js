// The Worker of the demo: app.com (npm run build) with the runtime of the
// npm package beam.com. The requests go to the Durable Object Beam: one VM,
// and its SQLite storage for the database.
import app from './app.com';
import { use } from 'beam.com';
use(app);
export { default, Beam } from 'beam.com';
